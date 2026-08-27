[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string]$OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) ('.test-output\pipeline-recovery-' + [guid]::NewGuid().ToString('N'))),
    [string]$CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($CodexHome) { $CodexHome = [IO.Path]::GetFullPath($CodexHome) }
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$watcher = Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1'
$mockAz = Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1'
$classifier = Join-Path $root 'scripts\Classify-PipelineFailure.ps1'
$commit = '0123456789abcdef0123456789abcdef01234567'

function Invoke-RecoveryWatcherScenario {
    param([Parameter(Mandatory)][string]$Scenario)
    $resultPath = Join-Path $OutputRoot "$Scenario-result.json"
    $env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = $Scenario
    $env:ECOSYSTEM_MOCK_COMMIT = $commit
    try {
        & $watcher -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $commit -DefinitionIds 17 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 0 -RunTimeoutMinutes 1 -AzCli $mockAz -TaskId "pipeline-$Scenario" -RepositoryId 'azure-palantirplugins-ps-app-delfi' -ResultPath $resultPath -ClassifierScript $classifier -PassThru
    }
    finally {
        Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
        Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
    }
}

$zeroResult = Invoke-RecoveryWatcherScenario -Scenario 'recovery-zero'
if ([string]$zeroResult.overallResult -ne 'no-run' -or @($zeroResult.runs).Count -ne 0) {
    throw 'Zero Azure results were not normalized to an explicit empty run collection.'
}

$singletonStringResult = Invoke-RecoveryWatcherScenario -Scenario 'recovery-singleton-string'
if ([string]$singletonStringResult.overallResult -ne 'succeeded' -or @($singletonStringResult.runs).Count -ne 1 -or [int]$singletonStringResult.runs[0].id -ne 9126) {
    throw 'A singleton PR run with JSON-string source-commit parameters was not correlated to the exact commit.'
}

$singletonObjectResult = Invoke-RecoveryWatcherScenario -Scenario 'recovery-singleton-object'
if ([string]$singletonObjectResult.overallResult -ne 'succeeded' -or @($singletonObjectResult.runs).Count -ne 1 -or [int]$singletonObjectResult.runs[0].id -ne 9127) {
    throw 'A singleton PR run with object source-commit parameters was not correlated to the exact commit.'
}

$mismatchResult = Invoke-RecoveryWatcherScenario -Scenario 'recovery-mismatch'
if ([string]$mismatchResult.overallResult -ne 'no-run' -or @($mismatchResult.runs).Count -ne 0) {
    throw 'A mismatched PR source commit was accepted for exact-commit monitoring.'
}

$multipleResult = Invoke-RecoveryWatcherScenario -Scenario 'recovery-multiple'
$multipleIds = @($multipleResult.runs | ForEach-Object { [int]$_.id } | Sort-Object)
if ([string]$multipleResult.overallResult -ne 'succeeded' -or ($multipleIds -join ',') -ne '9130,9131') {
    throw 'Multiple Azure results did not preserve direct and PR exact-commit matches while rejecting malformed, absent, mismatched, or unconfigured runs.'
}
if (@($multipleResult.queuedDefinitionIds).Count -ne 0) { throw 'Passive definition 17 observation queued a pipeline.' }

$wrapperRoot = Join-Path $OutputRoot 'production-wrapper'
$wrapperWorkspace = Join-Path $wrapperRoot 'repository'
$wrapperStateRoot = Join-Path $wrapperRoot 'state'
$wrapperCodexHome = if ($CodexHome) { $CodexHome } else { Join-Path $wrapperRoot 'codex-home' }
New-Item -ItemType Directory -Path $wrapperWorkspace,$wrapperStateRoot,$wrapperCodexHome -Force | Out-Null
& git -C $wrapperWorkspace init --quiet
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the in-workspace post-push wrapper fixture.' }
$wrapperCommit = ([string]('pipeline recovery fixture' | & git -C $wrapperWorkspace hash-object -w --stdin)).Trim()
if ($LASTEXITCODE -ne 0 -or $wrapperCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Could not create the in-workspace wrapper fixture object.' }
$wrapperBranch = 'feature/recovery-wrapper'
& git -C $wrapperWorkspace update-ref "refs/remotes/origin/$wrapperBranch" $wrapperCommit
if ($LASTEXITCODE -ne 0) { throw 'Could not create the in-workspace exact remote fixture ref.' }

$wrapperConfigPath = Join-Path $wrapperRoot 'agents.json'
$wrapperConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$wrapperConfig.runtime.stateRoot = $wrapperStateRoot
$wrapperRepository = @($wrapperConfig.repositories | Where-Object { [string]$_.id -eq 'azure-palantirplugins-ps-app-delfi' }) | Select-Object -First 1
$wrapperRepository.localWorkspace = $wrapperWorkspace
$wrapperRepository.organizationUrl = 'https://dev.azure.com/example'
$wrapperRepository.project = 'Example'
$wrapperPipeline = @($wrapperConfig.pipeline.repositories | Where-Object { [string]$_.repositoryId -eq 'azure-palantirplugins-ps-app-delfi' }) | Select-Object -First 1
$wrapperPipeline.definitionIds = @(17)
$wrapperPipeline.autoQueueDefinitionIds = @()
Write-Utf8NoBom -Path $wrapperConfigPath -Content (($wrapperConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

$wrapperTaskId = 'pipeline-wrapper-' + [guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $wrapperTaskId -TaskSelector 'synthetic post-push recovery' -Mode manual -RepositoryIds 'azure-palantirplugins-ps-app-delfi' -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome | Out-Null
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'recovery-singleton-string'
$env:ECOSYSTEM_MOCK_COMMIT = $wrapperCommit
try {
    $wrapperResult = & (Join-Path $root 'scripts\Invoke-PostPushPipeline.ps1') -TaskId $wrapperTaskId -RepositoryId 'azure-palantirplugins-ps-app-delfi' -PushWasSuccessful -Branch $wrapperBranch -Commit $wrapperCommit -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -AzCli $mockAz -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
if ([string]$wrapperResult.PipelineResult.overallResult -ne 'succeeded' -or @($wrapperResult.PipelineResult.runs).Count -ne 1 -or @($wrapperResult.PipelineResult.queuedDefinitionIds).Count -ne 0) {
    throw 'The production post-push wrapper did not consume exactly one passive PR-validation result without queueing.'
}

$refreshTaskId = 'pipeline-refresh-' + [guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $refreshTaskId -TaskSelector 'synthetic successful pipeline refresh' -Mode manual -RepositoryIds 'azure-palantirplugins-ps-app-delfi' -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome | Out-Null
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'recovery-singleton-string'
$env:ECOSYSTEM_MOCK_COMMIT = $wrapperCommit
try {
    $refreshResult = & (Join-Path $root 'scripts\Refresh-TaskPipelineResult.ps1') -TaskId $refreshTaskId -RepositoryId 'azure-palantirplugins-ps-app-delfi' -Branch $wrapperBranch -Commit $wrapperCommit -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -AzCli $mockAz -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
$refreshTask = Get-Content -LiteralPath (Join-Path $wrapperStateRoot "tasks\$refreshTaskId\task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$refreshEvents = @(Get-Content -LiteralPath (Join-Path $wrapperStateRoot "tasks\$refreshTaskId\task-ledger.jsonl") -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
$refreshAgentResults = @($refreshEvents | Where-Object { [string]$_.type -eq 'agent-result' -and [string]$_.actor -eq 'pipeline_monitor' })
$refreshTerminal = & (Join-Path $root 'scripts\Assert-TargetAgentTerminalState.ps1') -TaskId $refreshTaskId -AgentId pipeline_monitor -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome
if (
    [string]$refreshResult.PipelineResult.overallResult -ne 'succeeded' -or
    -not (Test-Path -LiteralPath ([string]$refreshResult.ResultPath) -PathType Leaf) -or
    [string]$refreshTask.agentStatuses.pipeline_monitor.status -ne 'completed' -or
    $refreshAgentResults.Count -ne 1 -or
    -not [bool]$refreshTerminal.Terminal
) {
    throw 'A successful exact-SHA refresh did not publish one terminal Pipeline Monitor outcome accepted by the host lifecycle assertion.'
}

$mismatchTaskId = 'pipeline-wrapper-mismatch-' + [guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $mismatchTaskId -TaskSelector 'synthetic post-push mismatch' -Mode manual -RepositoryIds 'azure-palantirplugins-ps-app-delfi' -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome | Out-Null
$originGateRejected = $false
try {
    & (Join-Path $root 'scripts\Invoke-PostPushPipeline.ps1') -TaskId $mismatchTaskId -RepositoryId 'azure-palantirplugins-ps-app-delfi' -PushWasSuccessful -Branch $wrapperBranch -Commit 'ffffffffffffffffffffffffffffffffffffffff' -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -ConfigPath $wrapperConfigPath -CodexHome $wrapperCodexHome | Out-Null
}
catch {
    $originGateRejected = $_.Exception.Message -like 'origin/* does not point to exact pushed commit*'
}
if (-not $originGateRejected) { throw 'The production post-push wrapper did not preserve its exact origin branch/commit gate.' }

[pscustomobject][ordered]@{
    collectionShapes = 'passed'
    directCommitCorrelation = 'passed'
    pullRequestStringCorrelation = 'passed'
    pullRequestObjectCorrelation = 'passed'
    invalidCommitRejection = 'passed'
    passiveDefinitionId = 17
    queuedDefinitionCount = 0
    productionWrapper = 'passed'
    refreshTerminalOutcome = 'passed'
    originCommitGate = 'passed'
}
