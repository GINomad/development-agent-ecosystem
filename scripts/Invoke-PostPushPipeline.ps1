[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $RepositoryId,
    [Parameter(Mandatory)][switch] $PushWasSuccessful,
    [string] $Branch,
    [string] $Commit,
    [datetime] $QueuedAfter = [datetime]::UtcNow.AddMinutes(-5),
    [ValidateRange(0,3)][int] $RemediationCycle = 0,
    [string] $AzCli,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
if (-not $PushWasSuccessful) { throw 'Post-push monitoring requires confirmation that git push succeeded.' }
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.pipeline.enabled -or -not [bool]$config.pipeline.postPush.enabled) { throw 'Post-push pipeline monitoring is disabled.' }
$repository = @($config.repositories | Where-Object { [string]$_.id -eq $RepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
if (-not $repository) { throw "Enabled repository '$RepositoryId' was not found." }
if ([string]$repository.provider -ne 'azure-devops') { throw 'Post-push pipeline monitoring currently supports Azure DevOps repositories only.' }
$pipelineRepository = @($config.pipeline.repositories | Where-Object { [string]$_.repositoryId -eq $RepositoryId }) | Select-Object -First 1
if (-not $pipelineRepository) { throw "Repository '$RepositoryId' has no pipeline configuration." }

$workspace = [IO.Path]::GetFullPath([string]$repository.localWorkspace)
if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { throw "Git workspace was not found: $workspace" }
Push-Location $workspace
try {
    if (-not $Branch) {
        $Branch = (& git branch --show-current).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the current Git branch.' }
    }
    if (-not $Commit) {
        $Commit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the current Git commit.' }
    }
    if (-not $Branch -or $Commit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Could not resolve an exact branch and full commit SHA.' }
    $shortBranch = $Branch -replace '^refs/heads/', ''
    $remoteCommit = ([string](& git rev-parse "refs/remotes/origin/$shortBranch" 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $remoteCommit.Equals($Commit, [StringComparison]::OrdinalIgnoreCase)) { throw "origin/$shortBranch does not point to exact pushed commit $Commit. Refusing to monitor or queue an unrelated build." }

    $taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
    if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) { throw "Task '$TaskId' was not found." }
    $resultPath = Join-Path $taskRoot 'pipeline-result.json'
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId pipeline_monitor -AgentStatus running -Stage pipeline_post_push -Message "Monitoring exact pushed commit $($Commit.Substring(0,12)) on $shortBranch." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

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
        AutoQueueDefinitionIds = if ([bool]$config.pipeline.postPush.autoQueueApprovedBuilds) { @($pipelineRepository.autoQueueDefinitionIds) } else { @() }
        QueuedAfter = $QueuedAfter
        TaskId = $TaskId
        RepositoryId = $RepositoryId
        ResultPath = $resultPath
        ClassifierScript = (Join-Path $PSScriptRoot 'Classify-PipelineFailure.ps1')
        FailureLogTailLines = [int]$config.pipeline.postPush.failureLogTailLines
        FailureLogMaxBytes = [int]$config.pipeline.postPush.failureLogMaxBytes
        RemediationCycle = $RemediationCycle
        MaxRemediationCycles = [int]$config.pipeline.postPush.maxRemediationCycles
        ProgressHeartbeatSeconds = [int]$config.pipeline.postPush.activityHeartbeatSeconds
        ProgressCallback = $activityCallback
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($AzCli)) { $watcherParameters.AzCli = $AzCli }
    $watcherResults = @(& $watcher @watcherParameters)
    if ($watcherResults.Count -ne 1 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Pipeline watcher did not produce exactly one pipeline-result.json result.' }
    $result = $watcherResults[0]

    $summary = [string]$result.summary
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type pipeline-analysis -Summary $summary -Artifact $resultPath -Evidence @("branch:$shortBranch", "commit:$Commit") -TargetAgentId knowledge_keeper -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Publish-AgentOutcome.ps1') -TaskId $TaskId -AgentId pipeline_monitor -Summary $summary -ArtifactNames @('pipeline-result.json') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $remediationRequest = & (Join-Path $PSScriptRoot 'Request-PipelineRemediation.ps1') -TaskId $TaskId -PipelineResultPath $resultPath -ConfigPath $ConfigPath -CodexHome $CodexHome
    [pscustomobject]@{ PipelineResult=$result; Remediation=$remediationRequest; ResultPath=$resultPath }
}
catch {
    $message = $_.Exception.Message
    try { & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId pipeline_monitor -AgentStatus failed -Stage pipeline_post_push_failed -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null } catch {}
    throw
}
finally {
    Pop-Location
}
