[CmdletBinding()]
param(
    [string] $CompletedTaskId,
    [switch] $ElevatedApproved,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$queued = [Collections.Generic.List[object]]::new()
$tasksRoot = Join-Path $stateRoot 'tasks'
if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
    foreach ($taskFile in @(Get-ChildItem -LiteralPath $tasksRoot -Filter task.json -File -Recurse)) {
        try { $task = Get-Content -LiteralPath $taskFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([string]$task.status -ne 'queued' -or [string]$task.taskId -eq $CompletedTaskId) { continue }
        $queued.Add($task)
    }
}
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$leasedTaskIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) {
    try {
        $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($lease in @($coordinator.leases)) { $null = $leasedTaskIds.Add([string]$lease.taskId) }
    }
    catch { }
}
$candidates = @($queued | Where-Object { -not $leasedTaskIds.Contains([string]$_.taskId) } | Sort-Object @{ Expression={ try { [DateTime]::Parse([string]$_.createdAtUtc).ToUniversalTime() } catch { [DateTime]::MaxValue } } }, @{ Expression={ [string]$_.taskId } })
if (-not $candidates.Count) { return [pscustomobject]@{ Status='empty'; TaskId=$null } }
foreach ($next in $candidates) {
    $repositoryIds = if ($next.PSObject.Properties['repositoryIds']) { @($next.repositoryIds) } elseif ($next.PSObject.Properties['repositoryId'] -and $next.repositoryId) { @([string]$next.repositoryId) } else { @() }
    $parameters = @{
        Mode = [string]$next.mode
        TaskSelector = [string]$next.selector
        TaskId = [string]$next.taskId
        RepositoryIds = @($repositoryIds)
        Resume = $true
        ConfigPath = $ConfigPath
        CodexHome = $CodexHome
    }
    if ($ElevatedApproved -or [bool]$config.workflow.automaticContinuation.useElevatedExecution) { $parameters.ElevatedApproved = $true }
    try { return & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @parameters }
    catch {
        if ($_.Exception.Message -match 'already has an active controller|active lease does not match') { continue }
        throw
    }
}
[pscustomobject]@{ Status='busy'; TaskId=$null; Message='Every queued candidate was admitted by another scheduler host.' }
