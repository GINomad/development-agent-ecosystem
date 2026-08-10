[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$root = Get-EcosystemRoot
$checks = [Collections.Generic.List[object]]::new()

function Add-Check {
    param([string] $Name, [string] $Detail)
    $checks.Add([pscustomobject]@{ Name=$Name; Status='passed'; Detail=$Detail })
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })
$parseErrors = [Collections.Generic.List[object]]::new()
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) {
        $parseErrors.Add([pscustomobject]@{ File=$file.FullName; Line=$error.Extent.StartLineNumber; Message=$error.Message })
    }
}
if ($parseErrors.Count) { throw "PowerShell syntax validation failed: $($parseErrors | ConvertTo-Json -Depth 5 -Compress)" }
Add-Check -Name 'powershell-syntax' -Detail "$($powerShellFiles.Count) files"

$automaticVariableWrites = @($powerShellFiles | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw) -match '(?im)^\s*\$pid\b\s*='
})
if ($automaticVariableWrites.Count) {
    throw "PowerShell scripts must not assign to the read-only automatic variable `$PID: $($automaticVariableWrites.FullName -join ', ')"
}
Add-Check -Name 'automatic-variable-writes' -Detail 'No assignments to $PID'

$jsonFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Recurse -Filter '*.json' -File)) { $jsonFiles.Add($file) }
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root '.agents\plugins\marketplace.json')))
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\.codex-plugin\plugin.json')))
foreach ($file in $jsonFiles) { $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
Add-Check -Name 'json-syntax' -Detail "$($jsonFiles.Count) files"

$dashboardServer = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
$dashboardClient = Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
$dashboardHtml = Get-Content -LiteralPath (Join-Path $root 'dashboard\index.html') -Raw -Encoding UTF8
foreach ($marker in @('/api/tasks','/agents/','/artifacts/','/comments','/diff','/close','/reopen','/api/external-reviews','/api/health-checks/run','/health-recovery/elevated','/workflow/elevated','/workflow/stop','/resume','Start-HealthTargetedResume.ps1','Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Add-TaskComment.ps1','Invoke-EcosystemHealthCheck.ps1','maximumPreviewBytes')) {
    if ($dashboardServer -notmatch [regex]::Escape($marker)) { throw "Dashboard server is missing task-monitor contract marker: $marker" }
}
if ($dashboardServer -notmatch 'Start-ScriptRunspace' -or $dashboardServer -notmatch 'in-process-runspace') { throw 'Elevated workflow must avoid the nested PowerShell process through a tracked in-process runspace.' }
if ($dashboardServer -notmatch 'tasks=@\(\$result\.Tasks\)') { throw 'Dashboard API must expose the task collection as lower-camel-case tasks.' }
foreach ($controlId in @('repositoryOptions','repositorySummary','taskList','taskDetail','inputRequiredPanel','openQuestions','taskInterventionPanel','taskComment','taskQuestionTarget','sendTaskComment','resumeTask','stopWorkflow','resumeElevatedWorkflow','executionPolicyNotice','runHealthCheck','artifactViewer','artifactContent','closeArtifactViewer','agentLogPanel','agentLogTitle','agentLogMeta','agentLogEntries','closeAgentLog','agentOutcomePanel','agentOutcomeTitle','agentOutcomeMeta','agentOutcomeSummary','agentOutcomeArtifacts','agentOutcomeArtifactMeta','agentOutcomeContent','closeAgentOutcome','openReviewDiff','reviewDiffPanel','reviewFeedbackTitle','reviewFeedbackSummary','reviewFeedbackList','reviewFeedbackStatus','externalReviewWorkspace','externalReviewList','externalReviewContent','refreshExternalReviews','manualClosePanel','manualCloseReason','closeTaskManually','reopenTaskPanel','reopenTaskReason','reopenTask','agentComment','agentActionStatus','sendAgentComment','restartAgentWithComment','approveElevatedRecovery')) {
    if ($dashboardHtml -notmatch ('id=["'']' + [regex]::Escape($controlId) + '["'']')) { throw "Dashboard UI is missing control: $controlId" }
    if ($dashboardClient -notmatch [regex]::Escape("#$controlId")) { throw "Dashboard client does not use control: $controlId" }
}
if ($dashboardServer -notmatch 'ReviewFindingId' -or $dashboardClient -notmatch 'review-finding:' -or $dashboardClient -notmatch 'Send to Reviewer' -or $dashboardClient -notmatch 'Send to Developer') { throw 'Reviewer feedback threads or addressable Reviewer/Developer replies are incomplete.' }
$reviewReplyRoot = Join-Path $OutputRoot 'review-feedback-reply'
$reviewReplyConfigPath = Join-Path $reviewReplyRoot 'agents.json'
$reviewReplyConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$reviewReplyConfig.runtime.stateRoot = Join-Path $reviewReplyRoot 'state'
Write-Utf8NoBom -Path $reviewReplyConfigPath -Content (($reviewReplyConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$reviewReplyTaskId = 'review-reply-' + [guid]::NewGuid().ToString('N')
$reviewReplyTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $reviewReplyTaskId -TaskSelector synthetic-review-reply -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $reviewReplyConfigPath
$reviewReply = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $reviewReplyTaskId -Text 'Implement the approved correction.' -TargetAgentId developer -ReviewFindingId REV-001 -ConfigPath $reviewReplyConfigPath
$reviewReplyEvent = Get-Content -LiteralPath (Join-Path $reviewReplyTask.TaskRoot 'task-ledger.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object eventId -eq $reviewReply.CommentId | Select-Object -First 1
if ([string]$reviewReply.ReviewFindingId -ne 'REV-001' -or [string]$reviewReply.TargetAgentId -ne 'developer' -or @($reviewReplyEvent.evidence) -notcontains 'review-finding:REV-001') { throw 'Reviewer feedback reply was not durably linked and targeted.' }
Add-Check -Name 'reviewer-feedback-replies' -Detail 'Reviewer summary/findings/process suggestions are visible; replies persist by finding ID and target Reviewer or Developer'
foreach ($scriptName in @('Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Get-AgentCommentBatch.ps1','Acknowledge-AgentCommentBatch.ps1','Write-AgentActivity.ps1','Add-TaskComment.ps1','Open-AgentQuestion.ps1','Set-AgentTaskStatus.ps1','Save-AgentCheckpoint.ps1','Publish-AgentOutcome.ps1','Start-HealthTargetedResume.ps1','Continue-AgentChain.ps1','Get-TaskDiff.ps1','Request-TaskClosure.ps1','Reopen-AgentTask.ps1','Invoke-ReviewedBranchDelivery.ps1','Sync-TaskPullRequestStatus.ps1','Sync-ActiveTaskPullRequests.ps1','Classify-PipelineFailure.ps1','Request-PipelineRemediation.ps1','Invoke-PostPushPipeline.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$scriptName") -PathType Leaf)) { throw "Task-monitor script is missing: $scriptName" }
}
if ($dashboardClient -notmatch 'selectedAgentId' -or $dashboardClient -notmatch 'loadAgentLog' -or $dashboardClient -notmatch 'agentLogRefreshSeconds \* 1000') { throw 'Dashboard per-agent live log polling is incomplete.' }
if ($dashboardServer -notmatch 'requiredArtifacts=@\(\$_.requiredArtifacts\)' -or $dashboardClient -notmatch 'agentRequiredArtifacts' -or $dashboardClient -notmatch 'openAgentOutcome') { throw 'Dashboard per-agent persisted outcome mapping is incomplete.' }
if ($dashboardServer -notmatch 'Stop-ValidatedWorkflowProcessTree' -or $dashboardServer -notmatch 'Stop-TaskScriptRunspaces') { throw 'Stop workflow must terminate only a validated task process tree or tracked runspace.' }
Add-Check -Name 'dashboard-task-monitor' -Detail 'Persistent tasks, per-agent status and live logs, open questions, targeted answers, resume controls, and safe artifact previews'

$workflowScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
$newTaskScript = Get-Content -LiteralPath (Join-Path $root 'scripts\New-AgentTask.ps1') -Raw -Encoding UTF8
$getTasksScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentTasks.ps1') -Raw -Encoding UTF8
$commentScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Add-TaskComment.ps1') -Raw -Encoding UTF8
if ($dashboardServer -notmatch 'Get-RequestedRepositoryIds' -or $dashboardClient -notmatch 'selectedRepositoryIds' -or $workflowScript -notmatch "--add-dir" -or $newTaskScript -notmatch 'repositoryIds') { throw 'Multi-repository selection is not wired through dashboard, task persistence, and workflow workspaces.' }
if ($getTasksScript -notmatch 'openQuestions' -or $commentScript -notmatch 'question-resolved' -or -not (Test-Path -LiteralPath (Join-Path $root 'scripts\Open-AgentQuestion.ps1'))) { throw 'Agent question and targeted answer lifecycle is incomplete.' }
if ($dashboardClient -notmatch 'taskStateRevision' -or $dashboardClient -notmatch "taskInterventionPanel'\)\.open = false") { throw 'Send comment must invalidate stale polling state, refresh task details, and collapse the intervention panel after success.' }
if ($dashboardClient -notmatch 'agentCommentDrafts' -or $dashboardClient -notmatch 'required: false' -or $dashboardClient -notmatch 'Comment is optional when restarting') { throw 'Per-agent comment drafts and comment-optional targeted restart are incomplete.' }
if ($dashboardServer -notmatch 'Get-ObjectPropertyValue' -or $dashboardServer -match '\$body\.(questionId|targetAgentId)') { throw 'Optional comment JSON properties must be read safely under PowerShell strict mode.' }
if ($commentScript -notmatch 'TargetAgentId' -or $dashboardClient -notmatch 'sendSelectedAgentComment' -or $workflowScript -notmatch 'Resume scope:' -or $workflowScript -notmatch 'MUST dispatch only') { throw 'Targeted comments and checkpoint-only resume are not wired end to end.' }
Add-Check -Name 'multi-repository-and-questions' -Detail 'Ordered repositoryIds, additional workspaces, visible open questions, targeted answers, and per-agent restart'

$requirementsPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\requirements-analyst.md') -Raw -Encoding UTF8
foreach ($excludedTree in @('node_modules','.nuget','vendor','bin','obj','dist','coverage')) {
    if ($requirementsPrompt -notmatch [regex]::Escape($excludedTree)) { throw ('Requirements Analyst first-party boundary is missing exclusion: ' + $excludedTree) }
}
if ($requirementsPrompt -notmatch 'first-party source code' -or $requirementsPrompt -notmatch 'Do not inspect the dependency') { throw 'Requirements Analyst must not analyze third-party dependency implementation.' }
Add-Check -Name 'requirements-first-party-boundary' -Detail 'Requirements Analyst excludes dependency implementations, caches, vendor trees, and generated output'

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ([int]$config.ui.agentLogRefreshSeconds -ne 30) { throw 'Default ui.agentLogRefreshSeconds must be 30.' }
if ([int]$config.runtime.contextLimits.maxSourceFiles -gt 100 -or [int]$config.runtime.contextLimits.maxCommandOutputBytes -gt 65536) { throw 'Default AI context limits are too broad.' }
if ([int]$config.review.maxFilesPerReview -gt 80 -or [int]$config.review.maxDiffCharacters -gt 500000) { throw 'Default PR review model-input limits are too broad.' }
$pipelineAgent = @($config.agents | Where-Object id -eq 'pipeline_monitor') | Select-Object -First 1
if ([string]$pipelineAgent.reasoningEffort -ne 'low') { throw 'Pipeline Monitor must use low reasoning effort for deterministic monitoring.' }
if (-not [bool]$config.pipeline.postPush.enabled -or [int]$config.pipeline.postPush.maxRemediationCycles -ne 3) { throw 'Post-push monitoring must be enabled with a three-cycle remediation ceiling.' }
if (-not [bool]$config.workflow.automaticContinuation.enabled -or [int]$config.workflow.automaticContinuation.maxChainSteps -ne 5 -or -not [bool]$config.workflow.automaticContinuation.useElevatedExecution) { throw 'Automatic targeted continuation configuration is incomplete.' }
if (-not [bool]$config.pipeline.delivery.autoPushAfterCleanReview -or [bool]$config.pipeline.delivery.allowForce -or [bool]$config.pipeline.delivery.allowTags -or [int]$config.pipeline.pullRequests.pollIntervalMinutes -ne 120) { throw 'Guarded delivery or two-hour PR lifecycle polling configuration is invalid.' }
if ([bool]$config.review.excludeSelfAuthored) { throw 'Review Monitor must include PRs authored by the configured reviewer as well as assigned PRs.' }
$excelPipeline = @($config.pipeline.repositories | Where-Object repositoryId -eq 'azure-planningspace-ps-excel-agent') | Select-Object -First 1
if ((@($excelPipeline.autoQueueDefinitionIds) -join ',') -ne '814,892' -or @($config.pipeline.repositories.autoQueueDefinitionIds) -contains 891) { throw 'Approved build definitions must be ordered 814 then 892; deployment 891 is forbidden.' }
Add-Check -Name 'configuration-semantics' -Detail "mode=$($config.operation.mode); repositories=$(@($config.repositories).Count); agents=$(@($config.agents).Count)"

$pipelineTestRoot = Join-Path $OutputRoot 'pipeline-monitor'
New-Item -ItemType Directory -Path $pipelineTestRoot -Force | Out-Null
$pipelineResultPath = Join-Path $pipelineTestRoot 'pipeline-result.json'
$pipelineTestTaskId = 'pipeline-test-' + [guid]::NewGuid().ToString('N')
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $pipelineResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -DefinitionIds 892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $pipelineResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -RemediationCycle 0 -MaxRemediationCycles 3 -PassThru
}
finally { Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue }
if ([string]$pipelineResult.overallResult -ne 'non-success' -or [string]$pipelineResult.failureClassification.category -ne 'code' -or [string]$pipelineResult.remediation.status -ne 'pending' -or [string]$pipelineResult.remediation.targetAgentId -ne 'developer' -or [int]$pipelineResult.remediation.cycle -ne 1) { throw 'Synthetic exact-SHA code failure was not classified and routed to Developer.' }
if (-not (Test-Path -LiteralPath $pipelineResultPath -PathType Leaf) -or (Get-Content -LiteralPath $pipelineResultPath -Raw | ConvertFrom-Json).commit -ne '0123456789abcdef0123456789abcdef01234567') { throw 'Structured pipeline-result.json was not persisted for the exact commit.' }
$sequenceStatePath = Join-Path $pipelineTestRoot 'ordered-sequence-state.txt'
$sequenceResultPath = Join-Path $pipelineTestRoot 'ordered-sequence-result.json'
Remove-Item -LiteralPath $sequenceStatePath -Force -ErrorAction SilentlyContinue
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'ordered-success'
$env:ECOSYSTEM_MOCK_PIPELINE_STATE = $sequenceStatePath
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $sequenceResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -AutoQueueDefinitionIds 814,892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $sequenceResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -RemediationCycle 0 -MaxRemediationCycles 3 -PassThru
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
$sequenceActions = @(Get-Content -LiteralPath $sequenceStatePath)
$queuedSequence = @($sequenceResult.queuedDefinitionIds) -join ','
$selectedSequence = @($sequenceResult.runs.definitionId) -join ','
$selectedRunIds = @($sequenceResult.runs.id)
if ([string]$sequenceResult.overallResult -ne 'succeeded' -or $queuedSequence -ne '814,892' -or $selectedSequence -ne '814,892' -or $selectedRunIds -contains 9800) { throw 'Ordered pipeline monitoring did not select and queue exact-SHA definitions 814 then 892.' }
if (($sequenceActions -join ',') -ne 'queued:814,succeeded:814,queued:892,succeeded:892') { throw 'Definition 892 was queued before exact-SHA definition 814 succeeded.' }
Add-Check -Name 'ordered-pipeline-sequence' -Detail 'Earlier 892 is ignored; 814 exact-SHA success gates queueing and acceptance of a later 892 run'
$infrastructureClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Publish image' -LogLines 'service connection authentication failed'
if ([string]$infrastructureClassification.category -ne 'infrastructure' -or [bool]$infrastructureClassification.developerEligible) { throw 'Infrastructure failure must not be routed to Developer.' }
$yamlClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Validate azure-pipelines.yml' -LogLines 'YAML syntax parse error: did not find expected key'
if ([string]$yamlClassification.category -ne 'code' -or -not [bool]$yamlClassification.developerEligible) { throw 'YAML pipeline configuration failures must route to Developer.' }
$pipelineTestConfigPath = Join-Path $pipelineTestRoot 'agents.json'
$pipelineTestConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pipelineTestConfig.runtime.stateRoot = (Join-Path $pipelineTestRoot 'state')
Write-Utf8NoBom -Path $pipelineTestConfigPath -Content (($pipelineTestConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$pipelineTestTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $pipelineTestTaskId -TaskSelector synthetic-pipeline-test -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $pipelineTestConfigPath
$firstRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$duplicateRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$pipelineTaskState = Get-Content -LiteralPath $pipelineTestTask.TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [bool]$firstRemediation.Requested -or [bool]$duplicateRemediation.Requested -or [string]$pipelineTaskState.agentStatuses.developer.status -ne 'pending' -or -not (Test-Path -LiteralPath $firstRemediation.Artifact -PathType Leaf)) { throw 'Developer pipeline remediation request was not persisted, targeted, or deduplicated.' }
Add-Check -Name 'post-push-pipeline-remediation' -Detail 'Exact-SHA run, bounded code/test classification, Developer routing, infrastructure exclusion, and three-cycle ceiling'

$lifecycleTaskId = 'pr-lifecycle-test-' + [guid]::NewGuid().ToString('N')
$lifecycleTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $lifecycleTaskId -TaskSelector synthetic-pr-lifecycle -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $pipelineTestConfigPath
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'delivery-result.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; repositoryId='azure-planningspace-ps-excel-agent'; branch='feature/synthetic-pr'; commit='0123456789abcdef0123456789abcdef01234567' } | ConvertTo-Json) + [Environment]::NewLine)
$activePrPath = Join-Path $pipelineTestRoot 'active-pr.json'
Write-Utf8NoBom -Path $activePrPath -Content ((@([ordered]@{ pullRequestId=123; status='active'; sourceRefName='refs/heads/feature/synthetic-pr'; title='Synthetic'; creationDate='2026-08-10T00:00:00Z'; createdBy=[ordered]@{ displayName='Test User' } }) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$activeSync = & (Join-Path $root 'scripts\Sync-TaskPullRequestStatus.ps1') -TaskId $lifecycleTaskId -RepositoryId azure-planningspace-ps-excel-agent -PullRequestsJsonPath $activePrPath -DoNotStartKnowledgeUpdate -ConfigPath $pipelineTestConfigPath
if ([string]$activeSync.Status -ne 'waiting' -or [string]$activeSync.Result.status -ne 'active') { throw 'Active PR lifecycle status did not keep the task waiting.' }
$completedPrPath = Join-Path $pipelineTestRoot 'completed-pr.json'
Write-Utf8NoBom -Path $completedPrPath -Content ((@([ordered]@{ pullRequestId=123; status='completed'; sourceRefName='refs/heads/feature/synthetic-pr'; title='Synthetic'; creationDate='2026-08-10T00:00:00Z'; createdBy=[ordered]@{ displayName='Test User' } }) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$completedSync = & (Join-Path $root 'scripts\Sync-TaskPullRequestStatus.ps1') -TaskId $lifecycleTaskId -RepositoryId azure-planningspace-ps-excel-agent -PullRequestsJsonPath $completedPrPath -DoNotStartKnowledgeUpdate -ConfigPath $pipelineTestConfigPath
if ([string]$completedSync.Status -ne 'completion-requested' -or -not (Test-Path -LiteralPath (Join-Path $lifecycleTask.TaskRoot 'task-closure.json'))) { throw 'Completed PR did not request final Knowledge Keeper closure.' }
Add-Check -Name 'pull-request-lifecycle' -Detail 'Active PR waits; completed PR requests Knowledge Keeper closure; polling is fixture-backed and model-free'

$deliveryFixtureId = [guid]::NewGuid().ToString('N')
$deliveryTestRoot = Join-Path $OutputRoot "reviewed-branch-delivery-$deliveryFixtureId"
$deliveryWorkspace = Join-Path $deliveryTestRoot 'workspace'
New-Item -ItemType Directory -Path $deliveryWorkspace -Force | Out-Null
& git init --quiet --initial-branch "feature/$deliveryFixtureId" $deliveryWorkspace
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the reviewed-branch delivery fixture repository.' }
& git -C $deliveryWorkspace config user.email 'ecosystem-test@example.invalid'
& git -C $deliveryWorkspace config user.name 'Ecosystem Test'
Write-Utf8NoBom -Path (Join-Path $deliveryWorkspace 'fixture.txt') -Content "reviewed delivery fixture$([Environment]::NewLine)"
& git -C $deliveryWorkspace add -- fixture.txt
& git -C $deliveryWorkspace commit --quiet -m 'Create reviewed delivery fixture'
if ($LASTEXITCODE -ne 0) { throw 'Could not commit the reviewed-branch delivery fixture.' }
& git -C $deliveryWorkspace remote add origin 'https://example.invalid/synthetic-reviewed-delivery'
if ($LASTEXITCODE -ne 0) { throw 'Could not configure the reviewed-branch delivery fixture remote.' }

$deliveryConfigPath = Join-Path $deliveryTestRoot 'agents.json'
$deliveryConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$deliveryConfig.runtime.stateRoot = (Join-Path $deliveryTestRoot 'state')
$deliveryRepositoryId = 'azure-planningspace-ps-excel-agent'
$deliveryRepository = @($deliveryConfig.repositories | Where-Object id -eq $deliveryRepositoryId) | Select-Object -First 1
$deliveryRepository.localWorkspace = $deliveryWorkspace
$deliveryRepository.repository = 'synthetic-reviewed-delivery'
Write-Utf8NoBom -Path $deliveryConfigPath -Content (($deliveryConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

$legacyDeliveryTaskId = "legacy-delivery-$deliveryFixtureId"
$legacyDeliveryTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$legacyDeliveryTaskId"
New-Item -ItemType Directory -Path $legacyDeliveryTaskRoot -Force | Out-Null
$legacyDeliveryTask = [ordered]@{
    taskId = $legacyDeliveryTaskId
    repositoryId = $deliveryRepositoryId
    agentStatuses = [ordered]@{ reviewer = [ordered]@{ status = 'completed' } }
}
Write-Utf8NoBom -Path (Join-Path $legacyDeliveryTaskRoot 'task.json') -Content (($legacyDeliveryTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $legacyDeliveryTaskRoot 'review-result.json') -Content (([ordered]@{ findings=@(); heldScopeViolations=@() } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$deliveryPlan = & (Join-Path $root 'scripts\Invoke-ReviewedBranchDelivery.ps1') -TaskId $legacyDeliveryTaskId -RepositoryId $deliveryRepositoryId -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$deliveryPlan.repositoryId -ne $deliveryRepositoryId -or [string]$deliveryPlan.workspace -ne [IO.Path]::GetFullPath($deliveryWorkspace) -or [string]$deliveryPlan.branch -ne "feature/$deliveryFixtureId" -or [string]$deliveryPlan.pushRef -ne "HEAD:refs/heads/feature/$deliveryFixtureId") { throw 'Prepare-only reviewed delivery did not accept the legacy singular repositoryId task scope.' }
Add-Check -Name 'reviewed-branch-delivery-legacy-task' -Detail 'Prepare-only delivery accepts legacy singular repositoryId task state without pushing'

$legacyResumeTaskId = "legacy-targeted-resume-$deliveryFixtureId"
$legacyResumeTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$legacyResumeTaskId"
New-Item -ItemType Directory -Path $legacyResumeTaskRoot -Force | Out-Null
$legacyResumeFailureSignature = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$legacyResumeTask = [ordered]@{
    taskId = $legacyResumeTaskId
    selector = 'synthetic-legacy-targeted-resume'
    mode = 'manual'
    status = 'interrupted'
    repositoryId = $deliveryRepositoryId
}
$legacyResumeFailure = [ordered]@{
    taskId = $legacyResumeTaskId
    agentId = 'pipeline_monitor'
    failureSignature = $legacyResumeFailureSignature
    summary = 'Synthetic targeted-resume regression.'
    diagnostic = 'Synthetic deterministic ecosystem defect.'
}
$legacyResumeRecovery = [ordered]@{
    failureSignature = $legacyResumeFailureSignature
    status = 'repaired'
}
$legacyResumeTaskPath = Join-Path $legacyResumeTaskRoot 'task.json'
$legacyResumeFailurePath = Join-Path $legacyResumeTaskRoot 'agent-failure.json'
$legacyResumeRecoveryPath = Join-Path $legacyResumeTaskRoot 'health-recovery-result.json'
Write-Utf8NoBom -Path $legacyResumeTaskPath -Content (($legacyResumeTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path $legacyResumeFailurePath -Content (($legacyResumeFailure | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path $legacyResumeRecoveryPath -Content (($legacyResumeRecovery | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$legacyResumePlan = & (Join-Path $root 'scripts\Start-HealthTargetedResume.ps1') -TaskId $legacyResumeTaskId -FailurePath $legacyResumeFailurePath -RecoveryEvidencePath $legacyResumeRecoveryPath -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$legacyResumePlan.TargetAgentId -ne 'pipeline_monitor' -or @($legacyResumePlan.RepositoryIds).Count -ne 1 -or [string]$legacyResumePlan.RepositoryIds[0] -ne $deliveryRepositoryId) { throw 'Prepare-only targeted resume did not preserve the legacy singular repositoryId task scope.' }
Add-Check -Name 'health-targeted-resume-legacy-task' -Detail 'Prepare-only targeted resume normalizes legacy singular repositoryId task state without dispatching a workflow'

$knowledgePrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\knowledge-keeper.md') -Raw -Encoding UTF8
$taskProtocol = Get-Content -LiteralPath (Join-Path $root 'prompts\common\task-protocol.md') -Raw -Encoding UTF8
$healthPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\health-check.md') -Raw -Encoding UTF8
$resumeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -Raw -Encoding UTF8
$healthRecoveryScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentHealthRecovery.ps1') -Raw -Encoding UTF8
$healthTargetedResumeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-HealthTargetedResume.ps1') -Raw -Encoding UTF8
$healthRecoverySchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\health-recovery-result.schema.json') -Raw -Encoding UTF8
if ($knowledgePrompt -notmatch 'Never cyclically poll' -or $knowledgePrompt -notmatch 'explicit agent knowledge or skill requests') { throw 'Knowledge Keeper is not pull-based or still permits subagent polling.' }
if ($taskProtocol -notmatch 'Publish-AgentOutcome.ps1' -or $taskProtocol -notmatch 'agent-checkpoints' -or $taskProtocol -notmatch 'autonomous bounded work blocks' -or $taskProtocol -notmatch 'Get-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Acknowledge-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'same agent invocation') { throw 'Private checkpoint, autonomous work-block, successful outcome, or end-of-block comment contract is missing.' }
if ($dashboardHtml -notmatch 'finishing its current work block' -or $dashboardClient -notmatch 'no restart is needed') { throw 'Dashboard does not explain automatic end-of-block comment consumption.' }
if ($healthPrompt -notmatch 'health-diagnostic-context.json' -or $healthRecoveryScript -notmatch 'Get-BoundedTextTail' -or $healthRecoveryScript -notmatch 'workflowLogTailLines') { throw 'Health Check bounded diagnostic context is incomplete.' }
if ($healthPrompt -notmatch 'diagnosis is not a terminal outcome' -or $healthRecoveryScript -notmatch 'existingDiagnosis' -or $healthRecoveryScript -notmatch 'health-repair-routing.json' -or $healthRecoverySchema -notmatch 'routeAgentId' -or $healthRecoverySchema -notmatch 'repairOwner') { throw 'Health Check repair-or-route contract is incomplete.' }
if ($workflowScript -notmatch 'health_recovery_handoff' -or $workflowScript -notmatch 'DiagnosisPath') { throw 'A completed Health Check diagnosis is not handed to automatic recovery.' }
if ($healthPrompt -notmatch 'restart exactly the failed agentId' -or $taskProtocol -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Health Check prompt contract does not restrict post-repair execution to the failed agent.' }
if ($healthTargetedResumeScript -notmatch 'TargetAgentId = \$targetAgentId' -or $healthTargetedResumeScript -notmatch 'HealthRecoveryRetry = \$true' -or $healthTargetedResumeScript -notmatch 'maxAttemptsPerFailureSignature' -or $healthTargetedResumeScript -notmatch 'RecoveryEvidencePath') { throw 'Health Check targeted-resume launcher is missing its target, validation, or retry-loop guard.' }
if ($workflowScript -notmatch 'HealthRecoveryRetry' -or $workflowScript -notmatch '-not \$HealthRecoveryRetry' -or $healthRecoveryScript -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Workflow and Health recovery are not wired to the one-shot targeted retry.' }
if ($healthRecoveryScript -notmatch 'RecoveryDepth' -or $healthRecoveryScript -notmatch 'health_recovery_followup' -or $healthRecoveryScript -notmatch 'Write-AgentFailure.ps1' -or $healthRecoveryScript -notmatch "targetedResume.Status -eq 'failed'") { throw 'A failure exposed by post-repair targeted resume is not returned to bounded Health recovery.' }
if ($resumeScript -notmatch 'ChangedArtifactNames' -or $resumeScript -notmatch 'resume-artifact-index.json' -or $resumeScript -notmatch 'shareableArtifacts' -or $resumeScript -notmatch "-ne 'completed'") { throw 'Resume artifact fingerprinting or completed-outcome filtering is incomplete.' }
$knowledgeAgent = @($config.agents | Where-Object id -eq 'knowledge_keeper') | Select-Object -First 1
if (@($knowledgeAgent.requiredArtifacts) -notcontains 'task-summary.json' -or -not (Test-Path -LiteralPath (Join-Path $root 'config\schemas\task-summary.schema.json'))) { throw 'Final per-task summary contract is incomplete.' }
if ((Get-Content -LiteralPath (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -Raw -Encoding UTF8) -notmatch "latest exact-SHA pipeline result") { throw 'Final task publication does not reject a non-success latest pipeline result.' }
Add-Check -Name 'bounded-pull-orchestration' -Detail 'On-demand knowledge, terminal-only outcomes, private checkpoints, batched comments, artifact fingerprints, and bounded health tails'

$quorumRoute = & (Join-Path $root 'scripts\Get-AssignedTaskContext.ps1') -TaskSelector 'https://quorumsoftware.visualstudio.com/Quorum/_workitems/edit/1854726' -ResolveOnly -ConfigPath $ConfigPath -CodexHome $CodexHome
if ([string]$quorumRoute.SourceId -ne 'quorum-azure-boards' -or [int]$quorumRoute.WorkItemId -ne 1854726 -or [string]$quorumRoute.Organization -ne 'https://dev.azure.com/quorumsoftware' -or [string]$quorumRoute.Project -ne 'Quorum') {
    throw 'Legacy Azure DevOps task URL did not resolve to the configured Quorum task source.'
}
$ambiguousIdRejected = $false
try { $null = & (Join-Path $root 'scripts\Get-AssignedTaskContext.ps1') -WorkItemId 1854726 -ResolveOnly -ConfigPath $ConfigPath -CodexHome $CodexHome }
catch { $ambiguousIdRejected = $_.Exception.Message -match 'ambiguous across enabled task sources' }
if (-not $ambiguousIdRejected) { throw 'A bare work item ID must not silently select a task source when multiple sources are enabled.' }
Add-Check -Name 'manual-task-source-routing' -Detail 'Quorum URL preserves organization/project; ambiguous bare IDs fail before network access'

$assignedTaskContextScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AssignedTaskContext.ps1') -Raw -Encoding UTF8
foreach ($argumentContract in @("'--area','wit','--resource','comments','--route-parameters'", "'--api-version','7.1-preview'")) {
    if ($assignedTaskContextScript -notmatch [regex]::Escape($argumentContract)) { throw "Assigned task context comments fetch is missing Azure CLI contract: $argumentContract" }
}
foreach ($incompatibleArgument in @("'--resource','workItemComments'", "'--api-version','7.1-preview.4'")) {
    if ($assignedTaskContextScript -match [regex]::Escape($incompatibleArgument)) { throw "Assigned task context comments fetch retains incompatible Azure CLI argument: $incompatibleArgument" }
}
Add-Check -Name 'assigned-task-comments-cli-compatibility' -Detail 'Comments fetch uses resource comments and API 7.1-preview without network access'

$engineeringSkills = @('apply-engineering-principles','develop-dotnet','develop-javascript-typescript','develop-react')
foreach ($agentId in @('knowledge_keeper','developer','reviewer')) {
    $engineeringAgent = @($config.agents | Where-Object id -eq $agentId) | Select-Object -First 1
    if (-not $engineeringAgent) { throw "Engineering-guidance agent is missing: $agentId" }
    $skillPaths = @($engineeringAgent.skillPaths | ForEach-Object { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$_)) })
    foreach ($skillName in $engineeringSkills) {
        if ($skillPaths -notcontains $skillName) { throw "$agentId is missing required engineering skill: $skillName" }
    }
}
Add-Check -Name 'engineering-skill-routing' -Detail 'Knowledge Keeper, Developer, and Reviewer share common plus .NET/JS/React guidance'

$healthAgent = @($config.agents | Where-Object id -eq 'health_check') | Select-Object -First 1
if (-not $healthAgent) { throw 'Health Check Agent is missing from the canonical configuration.' }
if ([string]$healthAgent.sandboxMode -ne 'read-only') { throw 'Health Check Agent must remain read-only inside product workflows.' }
if ([bool]$config.health.automaticRecovery.allowProductCodeChanges -or [bool]$config.health.automaticRecovery.allowExternalWrites) { throw 'Automatic health recovery boundary is unsafe.' }
if ([string]$config.health.automaticRecovery.sandboxMode -ne 'workspace-write') { throw 'Unattended automatic health recovery must remain sandboxed.' }
if ([string]$config.health.automaticRecovery.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Elevated recovery must require explicit dashboard approval.' }
$targetedResumeConfig = $config.health.automaticRecovery.targetedResume
if (-not [bool]$targetedResumeConfig.enabled -or -not [bool]$targetedResumeConfig.requireSuccessfulRepair -or [int]$targetedResumeConfig.maxAttemptsPerFailureSignature -ne 1) { throw 'Health Check targeted resume must require validated repair and permit exactly one attempt.' }
if (@($targetedResumeConfig.allowedAgentIds) -contains 'health_check' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'requirements_analyst' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'developer') { throw 'Health Check targeted resume allowlist is unsafe or incomplete.' }
foreach ($healthScript in @('Invoke-EcosystemHealthCheck.ps1','Write-AgentFailure.ps1','Start-AgentHealthRecovery.ps1','Start-HealthTargetedResume.ps1','Invoke-GuardedCodex.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$healthScript") -PathType Leaf)) { throw "Health recovery script is missing: $healthScript" }
}
Add-Check -Name 'health-recovery-contract' -Detail "automatic=$($config.health.automaticRecovery.enabled); attempts=$($config.health.automaticRecovery.maxAttemptsPerFailureSignature); targetedAttempts=$($targetedResumeConfig.maxAttemptsPerFailureSignature); failedAgentOnly=true; sandbox=workspace-write; elevated=approval-gated; productWrites=false; externalWrites=false"

$guardTestRoot = Join-Path $OutputRoot 'execution-guard'
New-Item -ItemType Directory -Path $guardTestRoot -Force | Out-Null
$guardTest = & (Join-Path $root 'scripts\Invoke-GuardedCodex.ps1') -FilePath 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tests\fixtures\Emit-RepeatedCodexFailures.ps1')) -Prompt '' -WorkingDirectory $root -LogPath (Join-Path $guardTestRoot 'events.jsonl') -GuardArtifactPath (Join-Path $guardTestRoot 'guard.json') -MaxIdenticalFailures 3 -MaxRunMinutes 1 -PollMilliseconds 100
if (-not [bool]$guardTest.guardTriggered -or [int]$guardTest.identicalFailureCount -ne 3 -or [int]$guardTest.exitCode -ne 1 -or [string]$guardTest.reason -notmatch 'retry limit' -or -not (Test-Path -LiteralPath (Join-Path $guardTestRoot 'guard.json') -PathType Leaf)) { throw 'Execution guard did not stop the deterministic repeated-failure fixture after exactly three attempts.' }
Add-Check -Name 'execution-retry-guard' -Detail 'Three identical failures stop execution and produce a guard artifact'

$skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills') -Recurse -Filter 'SKILL.md' -File)
foreach ($file in $skillFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -notmatch '(?s)^---\r?\nname:\s*[a-z0-9-]+\r?\ndescription:\s*.+?\r?\n---') {
        throw "Invalid or missing skill frontmatter: $($file.FullName)"
    }
    $openAiYaml = Join-Path $file.Directory.FullName 'agents\openai.yaml'
    if (-not (Test-Path -LiteralPath $openAiYaml -PathType Leaf)) { throw "Skill UI metadata is missing: $openAiYaml" }
    $metadata = Get-Content -LiteralPath $openAiYaml -Raw -Encoding UTF8
    if ($metadata -notmatch '(?m)^interface:' -or $metadata -notmatch '(?m)^\s+display_name:' -or $metadata -notmatch '(?m)^\s+default_prompt:') { throw "Skill UI metadata is incomplete: $openAiYaml" }
}
Add-Check -Name 'skill-frontmatter' -Detail "$($skillFiles.Count) skills"

$agentOutput = Join-Path $OutputRoot 'agents'
& (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -OutputDirectory $agentOutput -CodexHome $CodexHome | Out-Null
$tomlFiles = @(Get-ChildItem -LiteralPath $agentOutput -Filter '*.toml' -File)
if ($tomlFiles.Count -ne @($config.agents).Count) { throw 'Generated agent definition count does not match configuration.' }
foreach ($file in $tomlFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -notmatch '(?m)^name = ' -or $content -notmatch '(?m)^developer_instructions = ' -or $content -notmatch '(?m)^\[\[skills\.config\]\]') {
        throw "Generated agent TOML is incomplete: $($file.FullName)"
    }
}
Add-Check -Name 'agent-compilation' -Detail "$($tomlFiles.Count) TOML definitions"

$compatibleAgentOutput = Join-Path $OutputRoot 'agents-host-compatible'
& (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -OutputDirectory $compatibleAgentOutput -CodexHome $CodexHome -IncludeHostCompatibilityProfile | Out-Null
$compatibleTomlFiles = @(Get-ChildItem -LiteralPath $compatibleAgentOutput -Filter '*.toml' -File)
$profileSuffix = [string]$config.runtime.elevatedFallback.agentProfileSuffix
$profileTomlFiles = @($compatibleTomlFiles | Where-Object BaseName -like "*$profileSuffix")
if ($compatibleTomlFiles.Count -ne (@($config.agents).Count * 2) -or $profileTomlFiles.Count -ne @($config.agents).Count) { throw 'Host-compatible agent profile count is incorrect.' }
foreach ($file in $profileTomlFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    if ($content -notmatch 'sandbox_mode = "danger-full-access"' -or $content -notmatch 'OS policy compatibility profile') { throw "Host-compatible agent definition is incomplete: $($file.FullName)" }
}
Add-Check -Name 'host-compatible-agent-compilation' -Detail "$($profileTomlFiles.Count) derived profiles preserve prompts and use current-user execution"

$manifestPath = Join-Path (Resolve-EcosystemPath -Value ([string]$config.knowledge.managedRoot) -Config $config -CodexHome $CodexHome) '.knowledge-import.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Knowledge import manifest is missing: $manifestPath" }
$knowledgeManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (@($knowledgeManifest.entries).Count -lt 1) { throw 'Knowledge import manifest contains no entries.' }
Add-Check -Name 'knowledge-import' -Detail "$(@($knowledgeManifest.entries).Count) versioned files"

$reviewConfig = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $reviewConfig.ConfigPath -PathType Leaf)) { throw 'Derived review monitor configuration was not generated.' }
$reviewWrapper = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-EnhancedReview.ps1') -Raw -Encoding UTF8
$commentCollector = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-ActivePullRequestComments.ps1') -Raw -Encoding UTF8
$reviewRunner = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pr-review-monitor\scripts\run_pr_review_monitor.ps1') -Raw -Encoding UTF8
if ($reviewWrapper -match 'rerunWhenCommentsChange\s*-and\s*\[bool\]\$comments\.Changed' -or $reviewWrapper -notmatch 'ForceReviewKey') { throw 'A changed PR comment must not become a global ForceReview.' }
if ($commentCollector -notmatch 'ChangedPullRequestKeys' -or $commentCollector -notmatch 'pending-review-changes.json' -or $reviewRunner -notmatch 'requires-human-intervention') { throw 'Per-PR review invalidation and pending human state are incomplete.' }
Add-Check -Name 'review-monitor-config' -Detail $reviewConfig.ConfigPath
Add-Check -Name 'per-pr-review-invalidation' -Detail 'Only the changed PR is forced; unprocessed and failed AI review state remains visible'

[pscustomobject]@{
    Passed = $true
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    Checks = @($checks)
}
