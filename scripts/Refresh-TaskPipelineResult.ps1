[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $RepositoryId,
    [string] $Branch,
    [string] $Commit,
    [datetime] $QueuedAfter,
    [ValidateRange(0,10)][int] $DiscoveryTimeoutMinutes = 0,
    [string] $AzCli,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($RepositoryId)) {
    $RepositoryId = if ($task.PSObject.Properties['repositoryIds'] -and @($task.repositoryIds).Count) { [string]@($task.repositoryIds)[0] } else { [string]$task.repositoryId }
}
$repository = @($config.repositories | Where-Object { [string]$_.id -eq $RepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
if (-not $repository) { throw "Enabled repository '$RepositoryId' was not found." }
if ([string]$repository.provider -ne 'azure-devops') { throw 'Pipeline refresh currently supports Azure DevOps repositories only.' }
$pipelineRepository = @($config.pipeline.repositories | Where-Object { [string]$_.repositoryId -eq $RepositoryId }) | Select-Object -First 1
if (-not $pipelineRepository) { throw "Repository '$RepositoryId' has no pipeline configuration." }

$resolvedWorkspace = & (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -RepositoryId $RepositoryId -ConfigPath $ConfigPath -CodexHome $CodexHome
$workspace = [IO.Path]::GetFullPath([string]$resolvedWorkspace.Path)
if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { throw "Git workspace was not found: $workspace" }
Push-Location $workspace
try {
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $Branch = ([string](& git branch --show-current)).Trim()
        $branchExitCode = $LASTEXITCODE
        if ($branchExitCode -ne 0) { throw 'Could not resolve the task branch for pipeline refresh.' }
    }
    $shortBranch = $Branch -replace '^refs/heads/', ''
    if ([string]::IsNullOrWhiteSpace($shortBranch)) { throw 'Could not resolve the task branch for pipeline refresh.' }
    if ([string]::IsNullOrWhiteSpace($Commit)) {
        $Commit = ([string](& git rev-parse HEAD)).Trim()
        $commitExitCode = $LASTEXITCODE
        if ($commitExitCode -ne 0) { throw 'Could not resolve an exact local commit for pipeline refresh.' }
    }
    if ($Commit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Could not resolve an exact local commit for pipeline refresh.' }
    $remoteCommit = ([string](& git rev-parse "refs/remotes/origin/$shortBranch" 2>$null)).Trim()
    $remoteCommitExitCode = $LASTEXITCODE
    if ($remoteCommitExitCode -ne 0 -or -not $remoteCommit.Equals($Commit, [StringComparison]::OrdinalIgnoreCase)) {
        throw "origin/$shortBranch does not point to exact local commit $Commit. Read-only refresh will not analyze an unrelated commit."
    }
    if (-not $PSBoundParameters.ContainsKey('QueuedAfter')) {
        $QueuedAfter = if ($task.PSObject.Properties['createdAtUtc']) { [DateTime]::Parse([string]$task.createdAtUtc).ToUniversalTime() } else { [DateTime]::UtcNow.AddDays(-7) }
    }

    $resultPath = Join-Path $taskRoot 'pipeline-result.json'
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status running -AgentId pipeline_monitor -AgentStatus running -Stage pipeline_refresh -Message "Refreshing existing exact-SHA runs for $($Commit.Substring(0,12)) without queueing or pushing." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId pipeline_monitor -Level progress -Stage pipeline_refresh -Summary "Refreshing Azure pipeline evidence for $($Commit.Substring(0,12))." -Details 'This observation is read-only and does not depend on pull-request creation.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

    $watcher = Join-Path (Resolve-EcosystemPath -Value ([string]$config.pipeline.monitorSkillRoot) -Config $config -CodexHome $CodexHome) 'scripts\watch_pipeline_runs.ps1'
    $activityWriter = Join-Path $PSScriptRoot 'Write-AgentActivity.ps1'
    $activityCallback = {
        param([string]$Stage, [string]$Summary, [string]$Details)
        & $activityWriter -TaskId $TaskId -AgentId pipeline_monitor -Level progress -Stage $Stage -Summary $Summary -Details $Details -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }.GetNewClosure()
    $watcherParameters = @{
        Organization = [string]$repository.organizationUrl
        Project = [string]$repository.project
        Branch = $shortBranch
        Commit = $Commit
        DefinitionIds = @($pipelineRepository.definitionIds)
        AutoQueueDefinitionIds = @()
        QueuedAfter = $QueuedAfter
        DiscoveryTimeoutMinutes = $DiscoveryTimeoutMinutes
        LatestRunPerDefinition = $true
        TaskId = $TaskId
        RepositoryId = $RepositoryId
        ResultPath = $resultPath
        ClassifierScript = (Join-Path $PSScriptRoot 'Classify-PipelineFailure.ps1')
        FailureLogTailLines = [int]$config.pipeline.postPush.failureLogTailLines
        FailureLogMaxBytes = [int]$config.pipeline.postPush.failureLogMaxBytes
        MaxRemediationCycles = [int]$config.pipeline.postPush.maxRemediationCycles
        ProgressHeartbeatSeconds = [int]$config.pipeline.postPush.activityHeartbeatSeconds
        ProgressCallback = $activityCallback
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($AzCli)) { $watcherParameters.AzCli = $AzCli }
    $result = & $watcher @watcherParameters
    if (-not $result -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Pipeline refresh did not produce pipeline-result.json.' }

    $summary = "Refreshed existing exact-SHA pipeline evidence. $([string]$result.summary)"
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type pipeline-analysis -Summary $summary -Artifact $resultPath -Evidence @("branch:$shortBranch", "commit:$Commit", 'observation:read-only') -TargetAgentId knowledge_keeper -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $remediationRequest = & (Join-Path $PSScriptRoot 'Request-PipelineRemediation.ps1') -TaskId $TaskId -PipelineResultPath $resultPath -ConfigPath $ConfigPath -CodexHome $CodexHome
    if ([string]$result.overallResult -eq 'succeeded') {
        & (Join-Path $PSScriptRoot 'Publish-AgentOutcome.ps1') -TaskId $TaskId -AgentId pipeline_monitor -Summary $summary -ArtifactNames @('pipeline-result.json') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    elseif ([bool]$remediationRequest.Requested) {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -AgentId pipeline_monitor -AgentStatus completed -Stage pipeline_remediation_routed -Message $summary -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    else {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId pipeline_monitor -AgentStatus waiting -Stage pipeline_external_blocker -Message $summary -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    [pscustomobject]@{ PipelineResult=$result; Remediation=$remediationRequest; ResultPath=$resultPath; ReadOnly=$true }
}
catch {
    $message = $_.Exception.Message
    try { & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId pipeline_monitor -AgentStatus failed -Stage pipeline_refresh_failed -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null } catch {}
    throw
}
finally {
    Pop-Location
}
