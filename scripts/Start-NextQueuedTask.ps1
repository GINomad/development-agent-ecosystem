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
$next = @($queued | Sort-Object @{ Expression={ [DateTime]::Parse([string]$_.createdAtUtc).ToUniversalTime() } }, @{ Expression={ [string]$_.taskId } }) | Select-Object -First 1
if (-not $next) { return [pscustomobject]@{ Status='empty'; TaskId=$null } }
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
& (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @parameters
