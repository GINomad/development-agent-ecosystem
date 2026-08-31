[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $LeaseId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$now = [DateTime]::UtcNow.ToString('o')

Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    if (-not (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) { throw "Workspace coordinator state is missing for task '$TaskId'." }
    $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lease = @($coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId -and [string]$_.runId -eq $RunId -and [string]$_.leaseId -eq $LeaseId } | Select-Object -First 1)
    if (-not $lease.Count) { throw "Workspace lease '$LeaseId' is no longer owned by task '$TaskId' run '$RunId'." }
    $lease[0].heartbeatAtUtc = $now
    $coordinator.updatedAtUtc = $now
    Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
} | Out-Null

if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' disappeared while its workspace lease was active." }
Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $task.PSObject.Properties['executionRunId'] -or -not $task.PSObject.Properties['workspaceLeaseId'] -or [string]$task.executionRunId -ne $RunId -or [string]$task.workspaceLeaseId -ne $LeaseId) {
        throw "Task '$TaskId' state no longer matches workspace lease '$LeaseId'."
    }
    $task | Add-Member -NotePropertyName workflowHeartbeatAtUtc -NotePropertyValue $now -Force
    Write-Utf8NoBomAtomic -Path $taskPath -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
} | Out-Null

[pscustomobject]@{ Status='updated'; TaskId=$TaskId; RunId=$RunId; LeaseId=$LeaseId; HeartbeatAtUtc=$now }
