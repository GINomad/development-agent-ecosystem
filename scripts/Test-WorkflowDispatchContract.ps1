[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskId,
    [string] $TargetAgentId,
    [switch] $AllowUnroutedTarget,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$task = Get-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$routingPath = Join-Path $taskRoot ([string]$config.workflow.orchestration.routingArtifact)
$route = if (Test-Path -LiteralPath $routingPath) { @(Get-Content -LiteralPath $routingPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.PSObject.Properties['executionMode'] -and $_.PSObject.Properties['agentSequence'] }) | Select-Object -Last 1 } else { $null }
if (-not $route) {
    if ($TargetAgentId -and $TargetAgentId -ne [string]$config.workflow.orchestration.agentId -and $TargetAgentId -ne 'health_check' -and -not $AllowUnroutedTarget) { throw "Target agent '$TargetAgentId' cannot be dispatched before an execution mode is persisted." }
    return [pscustomobject]@{ Status='unrouted'; TaskId=$TaskId }
}
$mode = [string]$route.executionMode
$modeProperty = $config.workflow.orchestration.executionModes.PSObject.Properties[$mode]
if (-not $modeProperty) { throw "Persisted execution mode '$mode' is not configured." }
$sequence = @($route.agentSequence | ForEach-Object { [string]$_ })
if ((@($modeProperty.Value.agentSequence | ForEach-Object { [string]$_ }) -join '|') -ne ($sequence -join '|')) { throw "Persisted route '$mode' does not match the configured agent sequence." }
if ($TargetAgentId -and $TargetAgentId -notin $sequence -and $TargetAgentId -notin @('orchestrator','health_check')) { throw "Target agent '$TargetAgentId' is outside execution mode '$mode'." }
$repositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } else { @([string]$task.repositoryId) }
foreach ($repositoryId in $repositoryIds) {
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq [string]$repositoryId }) | Select-Object -First 1
    if (-not $repository) { throw "Task repository '$repositoryId' is not configured." }
    if ($repository.PSObject.Properties['allowedExecutionModes'] -and $mode -notin @($repository.allowedExecutionModes)) { throw "Execution mode '$mode' is not allowed for repository '$repositoryId'." }
}
if ($mode -eq 'local-poc-delivery' -and 'pipeline_monitor' -in $sequence) { throw 'Local POC delivery cannot require Pipeline Monitor.' }
[pscustomobject]@{ Status='valid'; TaskId=$TaskId; ExecutionMode=$mode; AgentSequence=$sequence; RepositoryIds=$repositoryIds }
