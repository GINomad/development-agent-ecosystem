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
$lockMetricsPath = Join-Path $stateRoot 'health\lock-metrics.jsonl'
$lockCorrelationId = "$TaskId/$RunId/$LeaseId"
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' disappeared while its workspace lease was active." }

# Do not nest the per-task and global coordinator locks. Validate the task before
# and after the short coordinator compare-and-swap; a competing resume wins safely.
$taskBeforeLeaseUpdate = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$actualRunId = if ($taskBeforeLeaseUpdate.PSObject.Properties['executionRunId']) { [string]$taskBeforeLeaseUpdate.executionRunId } else { '<missing>' }
$actualLeaseId = if ($taskBeforeLeaseUpdate.PSObject.Properties['workspaceLeaseId']) { [string]$taskBeforeLeaseUpdate.workspaceLeaseId } else { '<missing>' }
if ($actualRunId -ne $RunId -or $actualLeaseId -ne $LeaseId) { throw "Workspace lease '$LeaseId' is no longer owned by task '$TaskId' run '$RunId'. Expected run '$RunId' and lease '$LeaseId'; found run '$actualRunId' and lease '$actualLeaseId'." }

Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -MetricsPath $lockMetricsPath -CorrelationId $lockCorrelationId -Action {
    if (-not (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) { throw "Workspace coordinator state is missing for task '$TaskId'." }
    $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lease = @($coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId -and [string]$_.runId -eq $RunId -and [string]$_.leaseId -eq $LeaseId } | Select-Object -First 1)
    if (-not $lease.Count) { throw "Workspace lease '$LeaseId' is no longer owned by task '$TaskId' run '$RunId'." }
    $lease[0].heartbeatAtUtc = $now
    $coordinator.updatedAtUtc = $now
    Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
} | Out-Null

Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -MetricsPath $lockMetricsPath -CorrelationId $lockCorrelationId -Action {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actualRunId = if ($task.PSObject.Properties['executionRunId']) { [string]$task.executionRunId } else { '<missing>' }
    $actualLeaseId = if ($task.PSObject.Properties['workspaceLeaseId']) { [string]$task.workspaceLeaseId } else { '<missing>' }
    if ($actualRunId -ne $RunId -or $actualLeaseId -ne $LeaseId) { throw "Task '$TaskId' changed ownership while heartbeat was written; expected run '$RunId' and lease '$LeaseId'; found run '$actualRunId' and lease '$actualLeaseId'." }
    $task | Add-Member -NotePropertyName workflowHeartbeatAtUtc -NotePropertyValue $now -Force
    Write-Utf8NoBomAtomic -Path $taskPath -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
} | Out-Null

[pscustomobject]@{ Status='updated'; TaskId=$TaskId; RunId=$RunId; LeaseId=$LeaseId; HeartbeatAtUtc=$now }
