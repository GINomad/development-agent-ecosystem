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

function Invoke-SchedulerTestGit {
    param([Parameter(Mandatory)][string] $Workspace, [Parameter(Mandatory)][string[]] $Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Workspace @Arguments 2>&1)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) { throw "Scheduler test git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    @($output | ForEach-Object { [string]$_ })
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

$workflowRunner = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
if ($workflowRunner -notmatch '\$preserveAwaitingPullRequest\s*=\s*\$currentStatus\s+-eq\s+''interrupted''' -or $workflowRunner -notmatch '-not\s+\$preserveAwaitingPullRequest' -or $workflowRunner -notmatch '-Stage\s+awaiting_pull_request') {
    throw 'Targeted workflow completion must preserve the awaiting-pull-request lifecycle gate instead of marking the task completed.'
}
Add-Check -Name 'targeted-awaiting-pr-preservation' -Detail 'A completed Pipeline Monitor preserves interrupted/awaiting_pull_request until PR lifecycle evidence changes'

$scheduledTaskInstaller = Get-Content -LiteralPath (Join-Path $root 'scripts\Install-EcosystemScheduledTasks.ps1') -Raw -Encoding UTF8
if ($scheduledTaskInstaller -notmatch '\$backgroundPowerShellArguments\s*=\s*''-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass''' -or $scheduledTaskInstaller -notmatch '\$continuationArguments\s*=\s*"\$backgroundPowerShellArguments') {
    throw 'Scheduled ecosystem PowerShell tasks must use the shared hidden-window argument prefix.'
}
Add-Check -Name 'scheduled-task-hidden-window' -Detail 'All installed ecosystem PowerShell tasks use the shared -WindowStyle Hidden prefix'
$continuationHost = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentContinuationRecoveryHost.ps1') -Raw -Encoding UTF8
if ($scheduledTaskInstaller -notmatch 'Start-AgentContinuationRecoveryHost\.ps1' -or $scheduledTaskInstaller -notmatch '\$continuationTrigger\s*=\s*New-ScheduledTaskTrigger\s+-AtLogOn' -or $continuationHost -notmatch 'Repair-AgentContinuations\.ps1' -or $continuationHost -notmatch 'while\s*\(\$true\)' -or $continuationHost -notmatch '\[Math\]::Min\(60,\s*\$remainingSeconds\)' -or $continuationHost -notmatch 'Get-EcosystemConfig') {
    throw 'Continuation recovery must use one resident, config-reloading host instead of creating a PowerShell process every polling interval.'
}
Add-Check -Name 'resident-continuation-recovery' -Detail 'Recovery runs inside one at-logon hidden host, reloads JSON after each pass, and sleeps in bounded chunks'
if ($scheduledTaskInstaller -notmatch 'Development Ecosystem - Knowledge Weekly Report' -or $scheduledTaskInstaller -notmatch 'New-WeeklyKnowledgeReport\.ps1' -or $scheduledTaskInstaller -notmatch 'New-ScheduledTaskTrigger\s+-Weekly' -or $scheduledTaskInstaller -notmatch 'LogonType S4U') { throw 'Friday Knowledge Keeper report is not registered as a non-interactive weekly task.' }
Add-Check -Name 'weekly-knowledge-schedule' -Detail 'Weekly report uses the configured weekday/time and a non-interactive S4U task to avoid console windows'

$jsonFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Recurse -Filter '*.json' -File)) { $jsonFiles.Add($file) }
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root '.agents\plugins\marketplace.json')))
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\.codex-plugin\plugin.json')))
foreach ($file in $jsonFiles) { $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
Add-Check -Name 'json-syntax' -Detail "$($jsonFiles.Count) files"

$weeklyReportRoot = Join-Path $OutputRoot 'weekly-knowledge-report'
$weeklyReportConfigPath = Join-Path $weeklyReportRoot 'agents.json'
$weeklyReportStateRoot = Join-Path $weeklyReportRoot 'state'
$weeklyReportTaskRoot = Join-Path $weeklyReportStateRoot 'tasks\task-weekly-learning'
$weeklyReportOutputRoot = Join-Path $weeklyReportStateRoot 'reports\knowledge-weekly'
New-Item -ItemType Directory -Path $weeklyReportTaskRoot -Force | Out-Null
$weeklyReportConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$weeklyReportConfig.runtime.stateRoot = $weeklyReportStateRoot
$weeklyReportConfig.knowledge.taskHistoryRoot = Join-Path $weeklyReportStateRoot 'tasks'
$weeklyReportConfig.knowledge.weeklyReport.outputRoot = $weeklyReportOutputRoot
Write-Utf8NoBom -Path $weeklyReportConfigPath -Content (($weeklyReportConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$weeklyKnowledge = [ordered]@{ taskId='task-weekly-learning'; entries=@(
    [ordered]@{ id='STYLE-001'; status='verified'; statement='Prefer <safe> focused style rules.'; source='review:REV-201'; revision='git:abc123'; observedAtUtc='2026-08-13T08:00:00Z'; observedBy='knowledge_keeper'; targetPath='knowledge/decisions/coding-style.md' },
    [ordered]@{ id='IDEA-001'; status='proposed'; statement='Unverified idea must stay out.'; source='comment:draft'; revision='none'; observedAtUtc='2026-08-13T09:00:00Z'; observedBy='knowledge_keeper'; targetPath='knowledge/decisions/draft.md' },
    [ordered]@{ id='OLD-001'; status='superseded'; statement='An older process rule was replaced.'; source='decision:replacement'; revision='git:def456'; observedAtUtc='2026-08-13T10:00:00Z'; observedBy='knowledge_keeper'; targetPath='knowledge/decisions/process.md' }
) }
Write-Utf8NoBom -Path (Join-Path $weeklyReportTaskRoot 'knowledge-update.json') -Content (($weeklyKnowledge | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
$weeklySummary = [ordered]@{ taskId='task-weekly-learning'; status='completed'; completedAtUtc='2026-08-13T11:00:00Z'; repositories=@('repo-one'); outcomes=@(); decisions=@('Use the focused review style rule.'); verification=@('Reviewer approved REV-201.'); knowledgeUpdates=@('STYLE-001'); artifacts=@('knowledge-update.json'); residualItems=@() }
Write-Utf8NoBom -Path (Join-Path $weeklyReportTaskRoot 'task-summary.json') -Content (($weeklySummary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
$weeklyReportResult = & (Join-Path $root 'scripts\New-WeeklyKnowledgeReport.ps1') -AsOf ([DateTime]'2026-08-14T10:00:00') -ConfigPath $weeklyReportConfigPath
$weeklyReportJson = Get-Content -LiteralPath $weeklyReportResult.JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$weeklyReportHtml = Get-Content -LiteralPath $weeklyReportResult.HtmlPath -Raw -Encoding UTF8
if ([string]$weeklyReportResult.Status -ne 'generated' -or @($weeklyReportJson.verifiedLearning).Count -ne 1 -or @($weeklyReportJson.skillsAndPractices).Count -ne 1 -or @($weeklyReportJson.supersededLearning).Count -ne 1 -or @($weeklyReportJson.decisions).Count -ne 1 -or $weeklyReportHtml -notmatch '&lt;safe&gt;' -or $weeklyReportHtml -match 'Unverified idea must stay out') { throw 'Weekly Knowledge Keeper report did not preserve verified-only learning, categories, decisions, or HTML encoding.' }
Add-Check -Name 'weekly-knowledge-report' -Detail 'Verified Knowledge Keeper learning and completed decisions render to JSON and encoded HTML; proposed/private evidence is excluded'

$dashboardServer = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
$dashboardClient = Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
$dashboardHtml = Get-Content -LiteralPath (Join-Path $root 'dashboard\index.html') -Raw -Encoding UTF8
$dashboardCss = Get-Content -LiteralPath (Join-Path $root 'dashboard\styles.css') -Raw -Encoding UTF8
foreach ($marker in @('/api/tasks','/agents/','/artifacts/','/comments','/diff','/close','/reopen','/api/external-reviews','/external-review-report/','activePullRequests','/api/health-checks/run','/health-recovery/elevated','/workflow/elevated','/workflow/stop','/resume','Start-HealthTargetedResume.ps1','Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Add-TaskComment.ps1','Invoke-EcosystemHealthCheck.ps1','maximumPreviewBytes')) {
    if ($dashboardServer -notmatch [regex]::Escape($marker)) { throw "Dashboard server is missing task-monitor contract marker: $marker" }
}
if ($dashboardServer -notmatch 'Start-ScriptRunspace' -or $dashboardServer -notmatch 'in-process-runspace') { throw 'Elevated workflow must avoid the nested PowerShell process through a tracked in-process runspace.' }
if ($dashboardServer -match 'Start-ScriptProcess' -or $dashboardServer -match 'Start-Process\s+.*powershell' -or $dashboardServer -match 'ExecutionPolicy\s+Bypass') { throw 'Dashboard actions must not create nested PowerShell launchers that host security can block before task state exists.' }
if ($dashboardServer -notmatch '\[string\]::IsNullOrWhiteSpace\(\$ConfigPath\)' -or $dashboardServer -match '\[string\] \$ConfigPath = \(Join-Path') { throw 'Dashboard ConfigPath must be resolved after parameter binding so direct -File startup works in Windows PowerShell 5.1.' }
if ($dashboardServer -notmatch '\$elevatedRequested = \[bool\]\(Get-ObjectPropertyValue -Source \$body -Name ''elevated''\)' -or $dashboardServer -notmatch '\$workflowParameters\.ElevatedApproved = \$true' -or $dashboardClient -notmatch 'payload\.elevated = true' -or $dashboardClient -notmatch 'Start this workflow in host-compatible elevated mode') { throw 'Start Workflow elevated execution must require explicit UI confirmation and use the in-process runspace.' }
if ($dashboardServer -notmatch 'tasks=@\(\$result\.Tasks\)') { throw 'Dashboard API must expose the task collection as lower-camel-case tasks.' }
if ($dashboardServer -notmatch 'Test-TaskWorkflowActive' -or $dashboardServer -notmatch 'idle-awaiting-approval' -or $dashboardServer -notmatch 'queued-for-checkpoint' -or $dashboardClient -notmatch 'confirmIdleAgentDispatch' -or $dashboardClient -notmatch 'autoStartIdle: false') { throw 'Idle targeted comments are not wired to approval-gated immediate dispatch and active-workflow batching.' }
foreach ($controlId in @('repositoryOptions','repositorySummary','taskList','taskDetail','inputRequiredPanel','openQuestions','taskInterventionPanel','taskComment','taskQuestionTarget','sendTaskComment','resumeTask','stopWorkflow','resumeElevatedWorkflow','executionPolicyNotice','runHealthCheck','artifactViewer','artifactContent','closeArtifactViewer','agentLogPanel','agentLogTitle','agentLogMeta','agentLogEntries','closeAgentLog','agentOutcomePanel','agentOutcomeTitle','agentOutcomeMeta','agentOutcomeSummary','agentOutcomeArtifacts','agentOutcomeArtifactMeta','agentOutcomeContent','closeAgentOutcome','openReviewDiff','reviewDiffPanel','reviewFeedbackTitle','reviewFeedbackSummary','reviewFeedbackList','reviewFeedbackStatus','requirementTraceabilitySummary','requirementTraceabilityList','reviewDiffCommentDock','reviewDiffCommentPanel','externalReviewWorkspace','externalReviewList','externalReviewSummary','refreshExternalReviews','manualClosePanel','manualCloseReason','closeTaskManually','reopenTaskPanel','reopenTaskReason','reopenTask','agentComment','agentActionStatus','sendAgentComment','restartAgentWithComment','approveElevatedRecovery')) {
    if ($dashboardHtml -notmatch ('id=["'']' + [regex]::Escape($controlId) + '["'']')) { throw "Dashboard UI is missing control: $controlId" }
    if ($dashboardClient -notmatch [regex]::Escape("#$controlId")) { throw "Dashboard client does not use control: $controlId" }
}
if ($dashboardHtml -notmatch 'id=["'']requirementTraceabilityTitle["'']') { throw 'Dashboard UI is missing the Requirement Traceability heading.' }
foreach ($marker in @('resetReviewDiffCommentEditor','isSameSelection','renderInlineReviewerComments','renderRequirementTraceability','reviewerCodeLocation','row.dataset.newLine','click the selected line again to close','Select a diff line first.')) {
    if ($dashboardClient -notmatch [regex]::Escape($marker)) { throw "Dashboard local review is missing inline comment or traceability behavior: $marker" }
}
if ($dashboardHtml -notmatch 'reviewDiffCommentDock' -or $dashboardCss -notmatch 'height:\s*clamp\(420px,\s*68vh,\s*900px\)' -or $dashboardCss -notmatch 'scrollbar-gutter:\s*stable') { throw 'Dashboard diff viewer must keep the selected-line editor in the diff and provide independent file scrolling.' }
$reviewResultSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\review-result.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($reviewResultSchema.required) -notcontains 'requirementTraceability' -or -not $reviewResultSchema.properties.requirementTraceability -or -not $reviewResultSchema.'$defs'.finding.properties.codeLocation) { throw 'Review result schema must require requirement traceability and support structured inline code locations.' }
$reviewDecisionsSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\review-decisions.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$techDebtSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\tech-debt-items.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($reviewDecisionsSchema.properties.decisions.items.properties.decision.enum) -notcontains 'bypassed' -or -not $reviewDecisionsSchema.properties.decisions.items.properties.techDebtItemId -or -not $techDebtSchema.'$defs'.item.properties.sourceFindingId) { throw 'Review bypass decisions must require a linked task-local technical-debt item.' }
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
foreach ($scriptName in @('Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Get-AgentCommentBatch.ps1','Acknowledge-AgentCommentBatch.ps1','Request-OrchestratorCommentRouting.ps1','Set-WorkflowInputRoute.ps1','Switch-TaskWorkspace.ps1','Start-NextQueuedTask.ps1','Write-AgentActivity.ps1','Add-TaskComment.ps1','Open-AgentQuestion.ps1','Resolve-StaleAgentQuestions.ps1','Resolve-RecoveredControlPlaneStatuses.ps1','Assert-TargetAgentTerminalState.ps1','Set-AgentTaskStatus.ps1','Save-AgentCheckpoint.ps1','Publish-AgentOutcome.ps1','Start-HealthTargetedResume.ps1','Continue-AgentChain.ps1','Repair-AgentContinuations.ps1','Start-AgentContinuationRecoveryHost.ps1','New-WeeklyKnowledgeReport.ps1','Get-TaskDiff.ps1','Set-ReviewDecision.ps1','New-ReviewTechDebtItem.ps1','Request-TaskClosure.ps1','Reopen-AgentTask.ps1','Invoke-ReviewedBranchDelivery.ps1','Refresh-TaskPipelineResult.ps1','Sync-TaskPullRequestStatus.ps1','Sync-ActiveTaskPullRequests.ps1','Classify-PipelineFailure.ps1','Request-PipelineRemediation.ps1','Invoke-PostPushPipeline.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$scriptName") -PathType Leaf)) { throw "Task-monitor script is missing: $scriptName" }
}
if ($dashboardClient -notmatch 'selectedAgentId' -or $dashboardClient -notmatch 'loadAgentLog' -or $dashboardClient -notmatch 'agentLogRefreshSeconds \* 1000') { throw 'Dashboard per-agent live log polling is incomplete.' }
if ($dashboardServer -notmatch 'requiredArtifacts=@\(\$_.requiredArtifacts\)' -or $dashboardClient -notmatch 'agentRequiredArtifacts' -or $dashboardClient -notmatch 'openAgentOutcome') { throw 'Dashboard per-agent persisted outcome mapping is incomplete.' }
if ($dashboardServer -notmatch 'Stop-ValidatedWorkflowProcessTree' -or $dashboardServer -notmatch 'Stop-TaskScriptRunspaces') { throw 'Stop workflow must terminate only a validated task process tree or tracked runspace.' }
$activityWriter = Get-Content -LiteralPath (Join-Path $root 'scripts\Write-AgentActivity.ps1') -Raw -Encoding UTF8
$activityReader = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentActivity.ps1') -Raw -Encoding UTF8
$taskProtocol = Get-Content -LiteralPath (Join-Path $root 'prompts\common\task-protocol.md') -Raw -Encoding UTF8
foreach ($marker in @('Operation','Target','ProgressPercent','NextAction','Evidence')) {
    if ($activityWriter -notmatch ('\$' + $marker) -or $activityReader -notmatch ([char]::ToLowerInvariant($marker[0]) + $marker.Substring(1)) -or $dashboardClient -notmatch ([char]::ToLowerInvariant($marker[0]) + $marker.Substring(1))) { throw "Detailed agent activity field is not wired end-to-end: $marker" }
}
if ($taskProtocol -notmatch 'before and after each material inspection group' -or $taskProtocol -notmatch 'Never expose hidden reasoning') { throw 'Every agent must publish bounded factual operational progress without hidden reasoning or secrets.' }
Add-Check -Name 'detailed-agent-activity' -Detail 'Every role has a structured, redacted operational log contract and the dashboard renders it'
$activityFixtureRoot = Join-Path $OutputRoot 'detailed-agent-activity'
$activityFixtureConfigPath = Join-Path $activityFixtureRoot 'agents.json'
$activityFixtureConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$activityFixtureConfig.runtime.stateRoot = Join-Path $activityFixtureRoot 'state'
New-Item -ItemType Directory -Path $activityFixtureRoot -Force | Out-Null
Write-Utf8NoBom -Path $activityFixtureConfigPath -Content (($activityFixtureConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$activityFixtureTaskId = 'activity-' + [guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $activityFixtureTaskId -TaskSelector synthetic-activity -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $activityFixtureConfigPath | Out-Null
& (Join-Path $root 'scripts\Write-AgentActivity.ps1') -TaskId $activityFixtureTaskId -AgentId developer -Level progress -Stage test -Summary 'Running focused checks' -Details 'Bounded operational detail.' -Operation test -Target 'installer tests' -ProgressPercent 50 -NextAction 'Publish validation result.' -Evidence @('tests:5/10','token=must-not-persist') -ConfigPath $activityFixtureConfigPath | Out-Null
$activityFixtureResult = & (Join-Path $root 'scripts\Get-AgentActivity.ps1') -TaskId $activityFixtureTaskId -AgentId developer -Tail 20 -ConfigPath $activityFixtureConfigPath
$activityFixtureEntry = @($activityFixtureResult.Entries | Where-Object id -ne 'current-status' | Select-Object -Last 1)[0]
$activityFixtureRaw = Get-Content -LiteralPath (Join-Path $activityFixtureConfig.runtime.stateRoot "tasks\$activityFixtureTaskId\agent-activity.jsonl") -Raw -Encoding UTF8
if (
    [string]$activityFixtureEntry.operation -ne 'test' -or [string]$activityFixtureEntry.target -ne 'installer tests' -or
    [int]$activityFixtureEntry.progressPercent -ne 50 -or [string]$activityFixtureEntry.nextAction -ne 'Publish validation result.' -or
    @($activityFixtureEntry.evidence) -notcontains 'tests:5/10' -or $activityFixtureRaw -match 'must-not-persist' -or $activityFixtureRaw -notmatch '\[redacted\]'
) { throw 'Detailed agent activity did not round-trip or redact secret-shaped evidence.' }
Add-Check -Name 'detailed-agent-activity-roundtrip' -Detail 'Structured operation, target, progress, next action, and evidence round-trip with persisted secret redaction'
Add-Check -Name 'dashboard-task-monitor' -Detail 'Persistent tasks, per-agent status and live logs, open questions, targeted answers, resume controls, and safe artifact previews'

$recoveryStatusRoot = Join-Path $OutputRoot 'recovered-control-plane-statuses'
$recoveryStatusConfigPath = Join-Path $recoveryStatusRoot 'agents.json'
$recoveryStatusConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$recoveryStatusConfig.runtime.stateRoot = Join-Path $recoveryStatusRoot 'state'
Write-Utf8NoBom -Path $recoveryStatusConfigPath -Content (($recoveryStatusConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$recoveryStatusTaskId = 'recovered-control-plane-' + [guid]::NewGuid().ToString('N')
$recoveryStatusTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $recoveryStatusTaskId -TaskSelector synthetic-control-plane-recovery -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $recoveryStatusConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $recoveryStatusTaskId -AgentId orchestrator -AgentStatus completed -ConfigPath $recoveryStatusConfigPath | Out-Null
Write-Utf8NoBom -Path (Join-Path $recoveryStatusTask.TaskRoot 'workflow-routing.jsonl') -Content (([ordered]@{ routingId='synthetic'; targetAgentId='requirements_analyst' } | ConvertTo-Json -Compress) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Add-TaskEvent.ps1') -TaskId $recoveryStatusTaskId -Actor orchestrator -Type agent-result -Summary 'Synthetic routing completed.' -Artifact (Join-Path $recoveryStatusTask.TaskRoot 'workflow-routing.jsonl') -ConfigPath $recoveryStatusConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $recoveryStatusTaskId -AgentId orchestrator -AgentStatus failed -Message 'Synthetic post-outcome runner cleanup failure.' -ConfigPath $recoveryStatusConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $recoveryStatusTaskId -AgentId health_check -AgentStatus waiting -Message 'Synthetic recovery is waiting for operator repair.' -ConfigPath $recoveryStatusConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $recoveryStatusTaskId -AgentId requirements_analyst -AgentStatus completed -ConfigPath $recoveryStatusConfigPath | Out-Null
Write-Utf8NoBom -Path (Join-Path $recoveryStatusTask.TaskRoot 'requirements-analysis.json') -Content ("{}" + [Environment]::NewLine)
& (Join-Path $root 'scripts\Add-TaskEvent.ps1') -TaskId $recoveryStatusTaskId -Actor requirements_analyst -Type agent-result -Summary 'Synthetic downstream outcome completed.' -Artifact (Join-Path $recoveryStatusTask.TaskRoot 'requirements-analysis.json') -ConfigPath $recoveryStatusConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $recoveryStatusTaskId -Status review_pending -Stage review_decision_required -ClearProcessId -ConfigPath $recoveryStatusConfigPath | Out-Null
$recoveryStatusResult = & (Join-Path $root 'scripts\Resolve-RecoveredControlPlaneStatuses.ps1') -TaskId $recoveryStatusTaskId -ConfigPath $recoveryStatusConfigPath
$recoveryStatusState = Get-Content -LiteralPath (Join-Path $recoveryStatusTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$recoveryStatusState.status -ne 'review_pending' -or [string]$recoveryStatusState.currentStage -ne 'review_decision_required' -or [string]$recoveryStatusState.agentStatuses.orchestrator.status -ne 'completed' -or [string]$recoveryStatusState.agentStatuses.health_check.status -ne 'completed' -or @($recoveryStatusResult.Reconciled) -notcontains 'orchestrator' -or @($recoveryStatusResult.Reconciled) -notcontains 'health_check') { throw 'Superseded Orchestrator and Health Check states were not safely reconciled without changing the task gate.' }
Add-Check -Name 'recovered-control-plane-statuses' -Detail 'Later successful agent outcomes reconcile stale Orchestrator/Health Check states while preserving the active task gate and failure history'

$terminalStateTaskId = 'target-terminal-' + [guid]::NewGuid().ToString('N')
$terminalStateTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $terminalStateTaskId -TaskSelector synthetic-target-terminal -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $recoveryStatusConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $terminalStateTaskId -AgentId reviewer -AgentStatus running -ConfigPath $recoveryStatusConfigPath | Out-Null
$orphanRejected = $false
try { & (Join-Path $root 'scripts\Assert-TargetAgentTerminalState.ps1') -TaskId $terminalStateTaskId -AgentId reviewer -ConfigPath $recoveryStatusConfigPath | Out-Null }
catch { $orphanRejected = $_.Exception.Message -match "host run ended without a terminal agent status" }
if (-not $orphanRejected) { throw 'A targeted host run was allowed to exit while Reviewer remained running.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $terminalStateTaskId -AgentId reviewer -AgentStatus completed -ConfigPath $recoveryStatusConfigPath | Out-Null
$terminalStateResult = & (Join-Path $root 'scripts\Assert-TargetAgentTerminalState.ps1') -TaskId $terminalStateTaskId -AgentId reviewer -ConfigPath $recoveryStatusConfigPath
if (-not [bool]$terminalStateResult.Terminal -or [string]$terminalStateResult.AgentStatus -ne 'completed') { throw 'A valid completed targeted role was rejected by the host lifecycle assertion.' }
$targetWorkflowScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
if ($targetWorkflowScript -notmatch 'Execute that role''s work yourself in this Codex process' -or $targetWorkflowScript -notmatch 'do not merely announce or simulate a handoff' -or $targetWorkflowScript -notmatch 'Assert-TargetAgentTerminalState.ps1' -or $targetWorkflowScript -notmatch 'executedAgentId' -or $targetWorkflowScript -notmatch 'automaticContinuation.enabled' -or $targetWorkflowScript -match '\$TargetAgentId -and \$ContinueChain') { throw 'Host terminal lifecycle or configuration-driven automatic continuation is incomplete.' }
Add-Check -Name 'targeted-role-terminal-lifecycle' -Detail 'Targeted roles execute directly in the host Codex run; a host exit with running/pending state fails closed instead of leaving an orphaned dashboard status'

$workflowScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
$newTaskScript = Get-Content -LiteralPath (Join-Path $root 'scripts\New-AgentTask.ps1') -Raw -Encoding UTF8
$getTasksScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentTasks.ps1') -Raw -Encoding UTF8
$commentScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Add-TaskComment.ps1') -Raw -Encoding UTF8
if ($dashboardServer -notmatch 'Get-RequestedRepositoryIds' -or $dashboardClient -notmatch 'selectedRepositoryIds' -or $workflowScript -notmatch "--add-dir" -or $newTaskScript -notmatch 'repositoryIds') { throw 'Multi-repository selection is not wired through dashboard, task persistence, and workflow workspaces.' }
if ($getTasksScript -notmatch 'openQuestions' -or $commentScript -notmatch 'question-resolved' -or -not (Test-Path -LiteralPath (Join-Path $root 'scripts\Open-AgentQuestion.ps1'))) { throw 'Agent question and targeted answer lifecycle is incomplete.' }
if ($dashboardClient -notmatch 'taskStateRevision' -or $dashboardClient -notmatch "taskInterventionPanel'\)\.open = false") { throw 'Send comment must invalidate stale polling state, refresh task details, and collapse the intervention panel after success.' }
if ($dashboardClient -notmatch 'agentCommentDrafts' -or $dashboardClient -notmatch 'required: false' -or $dashboardClient -notmatch 'Comment is optional when restarting') { throw 'Per-agent comment drafts and comment-optional targeted restart are incomplete.' }
if ($dashboardServer -notmatch 'Get-ObjectPropertyValue' -or $dashboardServer -match '\$body\.(questionId|targetAgentId)') { throw 'Optional comment JSON properties must be read safely under PowerShell strict mode.' }
if ($commentScript -notmatch 'TargetAgentId' -or $dashboardClient -notmatch 'sendSelectedAgentComment' -or $workflowScript -notmatch 'Resume scope:' -or $workflowScript -notmatch 'MUST dispatch only' -or $workflowScript -notmatch 'Request-OrchestratorCommentRouting.ps1') { throw 'Targeted comments, authority returns, and checkpoint-only resume are not wired end to end.' }
Add-Check -Name 'multi-repository-and-questions' -Detail 'Ordered repositoryIds, additional workspaces, visible open questions, targeted answers, and per-agent restart'

$staleQuestionRoot = Join-Path $OutputRoot 'stale-agent-questions'
$staleQuestionConfigPath = Join-Path $staleQuestionRoot 'agents.json'
$staleQuestionConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$staleQuestionConfig.runtime.stateRoot = Join-Path $staleQuestionRoot 'state'
Write-Utf8NoBom -Path $staleQuestionConfigPath -Content (($staleQuestionConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$staleQuestionTaskId = 'stale-question-' + [guid]::NewGuid().ToString('N')
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $staleQuestionTaskId -TaskSelector synthetic-stale-question -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $staleQuestionConfigPath
$staleQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $staleQuestionTaskId -AgentId pipeline_monitor -Question 'Is this prior input still required?' -ConfigPath $staleQuestionConfigPath
$restartCutoff = [DateTime]::Parse([string]$staleQuestion.TimestampUtc).ToUniversalTime().AddMilliseconds(1)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $staleQuestionTaskId -Status interrupted -AgentId pipeline_monitor -AgentStatus completed -Stage targeted_agent_completed -Message 'Targeted restart completed without an input gate.' -ConfigPath $staleQuestionConfigPath | Out-Null
$staleResolution = & (Join-Path $root 'scripts\Resolve-StaleAgentQuestions.ps1') -TaskId $staleQuestionTaskId -AgentId pipeline_monitor -RestartedAtUtc $restartCutoff -ConfigPath $staleQuestionConfigPath
$staleQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $staleQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($staleResolution.SupersededQuestionIds) -notcontains [string]$staleQuestion.QuestionId -or @($staleQuestionView.Tasks[0].openQuestions).Count -ne 0) { throw 'A question made obsolete by a successful targeted restart remained visible on the dashboard.' }
$activeQuestionTaskId = 'active-question-' + [guid]::NewGuid().ToString('N')
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $activeQuestionTaskId -TaskSelector synthetic-active-question -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $staleQuestionConfigPath
$activeQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $activeQuestionTaskId -AgentId reviewer -Question 'This input is still required.' -ConfigPath $staleQuestionConfigPath
$activeCutoff = [DateTime]::Parse([string]$activeQuestion.TimestampUtc).ToUniversalTime().AddMilliseconds(1)
$activeResolution = & (Join-Path $root 'scripts\Resolve-StaleAgentQuestions.ps1') -TaskId $activeQuestionTaskId -AgentId reviewer -RestartedAtUtc $activeCutoff -ConfigPath $staleQuestionConfigPath
$activeQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $activeQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($activeResolution.PreservedQuestionIds) -notcontains [string]$activeQuestion.QuestionId -or @($activeQuestionView.Tasks[0].openQuestions).Count -ne 1) { throw 'An agent still waiting_for_input lost its active question.' }
Add-Check -Name 'stale-question-reconciliation' -Detail 'Successful targeted restart supersedes obsolete questions while an active waiting_for_input gate remains visible'

$routingRoot = Join-Path $OutputRoot 'workflow-routing'
$routingConfigPath = Join-Path $routingRoot 'agents.json'
$routingConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$routingConfig.runtime.stateRoot = Join-Path $routingRoot 'state'
Write-Utf8NoBom -Path $routingConfigPath -Content (($routingConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$routingTaskId = 'routing-' + [guid]::NewGuid().ToString('N')
$routingTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $routingTaskId -TaskSelector synthetic-routing -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $routingConfigPath
$generalComment = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $routingTaskId -Text 'Please implement the confirmed source-code correction.' -ConfigPath $routingConfigPath
if ([string]$generalComment.TargetAgentId -ne 'orchestrator' -or [string]$generalComment.RoutingStatus -ne 'pending-orchestrator') { throw 'Untargeted workflow comments must enter the Orchestrator queue.' }
$orchestratorBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId orchestrator -ConfigPath $routingConfigPath
if (@($orchestratorBatch.eventIds) -notcontains [string]$generalComment.CommentId) { throw 'Orchestrator did not receive the untargeted workflow comment.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $routingTaskId -AgentId developer -AgentStatus completed -Stage synthetic_preserved_target -Message 'Synthetic completed target must remain preserved during routing.' -ConfigPath $routingConfigPath | Out-Null
$route = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId $generalComment.CommentId -TargetAgentIds developer -Rationale 'The comment requests a product source-code change, which is Developer-owned.' -Confidence high -ConfigPath $routingConfigPath
$routeAgain = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId $generalComment.CommentId -TargetAgentIds reviewer -Rationale 'A duplicate route must return the persisted decision.' -Confidence low -ConfigPath $routingConfigPath
$developerBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId developer -ConfigPath $routingConfigPath
$orchestratorAfter = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId orchestrator -ConfigPath $routingConfigPath
$directComment = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $routingTaskId -Text 'Review the signing diff.' -TargetAgentId reviewer -ConfigPath $routingConfigPath
$orchestratorFinal = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId orchestrator -ConfigPath $routingConfigPath
$routingTaskAfter = Get-Content -LiteralPath (Join-Path $routingTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$route.Status -ne 'routed' -or [string]$routeAgain.Status -ne 'already-routed' -or @($route.Routing.targets) -notcontains 'developer') { throw 'Workflow routing is not durable and idempotent.' }
if (@($developerBatch.comments | Where-Object sourceEventId -eq $generalComment.CommentId).Count -ne 1 -or [int]$orchestratorAfter.count -ne 0 -or [int]$orchestratorFinal.count -ne 0 -or [string]$directComment.RoutingStatus -ne 'direct' -or [string]$routingTaskAfter.agentStatuses.developer.status -ne 'completed') { throw 'Routed inputs must remain addressable without changing a preserved target agent status.' }
if (-not (Test-Path -LiteralPath (Join-Path $routingTask.TaskRoot 'workflow-routing.jsonl') -PathType Leaf)) { throw 'workflow-routing.jsonl was not persisted.' }
Add-Check -Name 'workflow-orchestrator-routing' -Detail 'General comments route once; explicit targets remain direct; routed inputs are addressable without rewriting preserved target status'

& (Join-Path $root 'scripts\Acknowledge-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId developer -EventIds @($developerBatch.eventIds) -ConfigPath $routingConfigPath | Out-Null
$authorityHandoff = & (Join-Path $root 'scripts\Request-OrchestratorCommentRouting.ps1') -TaskId $routingTaskId -AgentId reviewer -EventIds $directComment.CommentId -Reason 'Build execution and Azure pipeline state are owned by Pipeline Monitor, not Reviewer.' -ConfigPath $routingConfigPath
$authorityHandoffAgain = & (Join-Path $root 'scripts\Request-OrchestratorCommentRouting.ps1') -TaskId $routingTaskId -AgentId reviewer -EventIds $directComment.CommentId -Reason 'Repeated checkpoint must reuse the durable handoff.' -ConfigPath $routingConfigPath
$handoffEventId = [string]$authorityHandoff.HandoffEventIds[0]
$reviewerAfterHandoff = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId reviewer -ConfigPath $routingConfigPath
$orchestratorHandoffBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId orchestrator -ConfigPath $routingConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $routingTaskId -AgentId reviewer -AgentStatus completed -ConfigPath $routingConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $routingTaskId -Status review_pending -Stage review_decision_required -ConfigPath $routingConfigPath | Out-Null
$orchestratorDispatch = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $routingTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $routingConfigPath
$handoffRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId $handoffEventId -TargetAgentIds pipeline_monitor -Rationale 'The forwarded remainder requests pipeline observation, which Pipeline Monitor owns.' -Confidence high -ConfigPath $routingConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $routingTaskId -AgentId orchestrator -AgentStatus completed -ConfigPath $routingConfigPath | Out-Null
$targetDispatch = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $routingTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $routingConfigPath
$pipelineHandoffBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId pipeline_monitor -ConfigPath $routingConfigPath
if ([string]$authorityHandoff.Status -ne 'forwarded' -or [string]$authorityHandoffAgain.Status -ne 'already-forwarded' -or [int]$reviewerAfterHandoff.count -ne 0 -or @($orchestratorHandoffBatch.comments | Where-Object eventType -eq 'agent-routing-request').Count -ne 1) { throw 'Agent authority handoff was not durable, idempotent, or atomically acknowledged.' }
if ([string]$orchestratorDispatch.NextAgentId -ne 'orchestrator' -or [string]$targetDispatch.NextAgentId -ne 'pipeline_monitor' -or [string]$handoffRoute.Status -ne 'routed' -or @($pipelineHandoffBatch.comments | Where-Object sourceEventId -eq $handoffEventId).Count -ne 1) { throw 'Authority handoff did not automatically prioritize Orchestrator and the newly selected owner across the review gate.' }
Add-Check -Name 'automatic-authority-handoff' -Detail 'Out-of-scope direct comments return once to Orchestrator with source traceability; host continuation prioritizes Orchestrator and its routed owner without manual restart'

$approvedProcessInput = & (Join-Path $root 'scripts\Add-TaskEvent.ps1') -TaskId $routingTaskId -Actor reviewer -Type workflow-input-routed -Summary 'Human-approved Reviewer process finding requires ecosystem maintenance.' -Evidence @('review-finding:REV-011','decision:approved') -TargetAgentId orchestrator -ConfigPath $routingConfigPath
$approvedProcessRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId ([string]$approvedProcessInput.eventId) -TargetAgentIds health_check -Rationale 'The approved process finding modifies the ecosystem control plane, which Health Check owns.' -Confidence high -ConfigPath $routingConfigPath
$approvedProcessRouteAgain = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId ([string]$approvedProcessInput.eventId) -TargetAgentIds developer -Rationale 'A duplicate route must preserve the original Health Check decision.' -Confidence low -ConfigPath $routingConfigPath
$orchestratorAfterApprovedProcess = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId orchestrator -ConfigPath $routingConfigPath
$healthCheckApprovedProcessBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $routingTaskId -AgentId health_check -ConfigPath $routingConfigPath
$preservedRoutedInput = & (Join-Path $root 'scripts\Add-TaskEvent.ps1') -TaskId $routingTaskId -Actor orchestrator -Type workflow-input-routed -Summary 'This routed input belongs directly to Reviewer.' -Evidence @('synthetic-explicit-target','routing:synthetic') -TargetAgentId reviewer -ConfigPath $routingConfigPath
$explicitRoutedTargetPreserved = $false
try {
    & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId ([string]$preservedRoutedInput.eventId) -TargetAgentIds developer -Rationale 'This reclassification must be rejected because Reviewer is the explicit target.' -Confidence high -ConfigPath $routingConfigPath | Out-Null
}
catch {
    $explicitRoutedTargetPreserved = $_.Exception.Message -eq "Routed workflow input '$([string]$preservedRoutedInput.eventId)' must be explicitly targeted to 'orchestrator' and cannot be reclassified."
}
if ([string]$approvedProcessRoute.Status -ne 'routed' -or [string]$approvedProcessRouteAgain.Status -ne 'already-routed' -or [string]$approvedProcessRoute.Routing.sourceType -ne 'workflow-input-routed' -or @($approvedProcessRoute.Routing.targets) -notcontains 'health_check') { throw 'Approved process input routing was not durable and idempotent.' }
if (@($orchestratorAfterApprovedProcess.eventIds) -contains [string]$approvedProcessInput.eventId -or @($healthCheckApprovedProcessBatch.comments | Where-Object sourceEventId -eq ([string]$approvedProcessInput.eventId)).Count -ne 1 -or -not $explicitRoutedTargetPreserved) { throw 'Approved process input routing did not preserve acknowledgement, addressability, or explicit targeting semantics.' }
Add-Check -Name 'approved-process-orchestrator-rerouting' -Detail 'Orchestrator-targeted approved process inputs route once, are acknowledged, remain addressable, and cannot override another explicit target'

$ecosystemMaintenanceComment = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $routingTaskId -Text 'Update the ecosystem runner contract and its regression tests.' -ConfigPath $routingConfigPath
$ecosystemMaintenanceRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId $ecosystemMaintenanceComment.CommentId -TargetAgentIds health_check -Rationale 'Source-controlled ecosystem maintenance belongs to Health Check.' -Confidence high -ConfigPath $routingConfigPath
$healthPriorityDispatch = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $routingTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $routingConfigPath
if ([string]$ecosystemMaintenanceRoute.Status -ne 'routed' -or [string]$healthPriorityDispatch.NextAgentId -ne 'health_check') { throw 'Health Check maintenance input did not preempt unrelated pending delivery work.' }
Add-Check -Name 'ecosystem-maintenance-dispatch' -Detail 'A routed Health Check maintenance request preempts unrelated pending delivery work without changing product scope'

$schedulerRoot = Join-Path $OutputRoot ('workspace-scheduler-' + [guid]::NewGuid().ToString('N'))
$schedulerWorkspace = Join-Path $schedulerRoot 'repository'
$schedulerConfigPath = Join-Path $schedulerRoot 'agents.json'
New-Item -ItemType Directory -Path $schedulerWorkspace -Force | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('init','-b','main') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('config','user.email','ecosystem-tests@example.invalid') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('config','user.name','Agent Ecosystem Tests') | Out-Null
Write-Utf8NoBom -Path (Join-Path $schedulerWorkspace 'tracked.txt') -Content "baseline$([Environment]::NewLine)"
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('add','tracked.txt') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('commit','-m','baseline') | Out-Null

$schedulerConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$schedulerConfig.runtime.stateRoot = Join-Path $schedulerRoot 'state'
$schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath = Join-Path $schedulerRoot 'state\workspace-coordinator.json'
$schedulerRepository = @($schedulerConfig.repositories | Where-Object id -eq 'azure-planningspace-ps-excel-agent') | Select-Object -First 1
$schedulerRepository.localWorkspace = $schedulerWorkspace
Write-Utf8NoBom -Path $schedulerConfigPath -Content (($schedulerConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

$taskAId = 'workspace-a-' + [guid]::NewGuid().ToString('N')
$taskBId = 'workspace-b-' + [guid]::NewGuid().ToString('N')
$taskCId = 'workspace-c-' + [guid]::NewGuid().ToString('N')
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskAId -TaskSelector synthetic-workspace-a -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('switch','-c','feature/task-a') | Out-Null
$leaseA = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskAId -ConfigPath $schedulerConfigPath
Write-Utf8NoBom -Path (Join-Path $schedulerWorkspace 'tracked.txt') -Content "task-a$([Environment]::NewLine)"
Write-Utf8NoBom -Path (Join-Path $schedulerWorkspace 'task-a-untracked.txt') -Content "task-a-untracked$([Environment]::NewLine)"
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status interrupted -Message 'Synthetic task A is idle.' -ConfigPath $schedulerConfigPath | Out-Null

$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskBId -TaskSelector synthetic-workspace-b -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
$leaseB = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskBId -ConfigPath $schedulerConfigPath
$branchAfterB = ((Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('branch','--show-current')) -join '').Trim()
$statusAfterB = @(Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('status','--porcelain=v1'))
$taskASessionPath = Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskAId\workspace-session.json"
$taskASuspended = Get-Content -LiteralPath $taskASessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$leaseA.Status -ne 'active' -or [string]$leaseB.Status -ne 'active' -or $branchAfterB -ne 'main' -or $statusAfterB.Count -ne 0 -or [string]::IsNullOrWhiteSpace([string]$taskASuspended.repositories[0].stashCommit)) { throw 'Switching to task B did not preserve and isolate task A changes.' }

Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('switch','-c','feature/task-b') | Out-Null
Write-Utf8NoBom -Path (Join-Path $schedulerWorkspace 'tracked.txt') -Content "task-b$([Environment]::NewLine)"
Write-Utf8NoBom -Path (Join-Path $schedulerWorkspace 'task-b-untracked.txt') -Content "task-b-untracked$([Environment]::NewLine)"
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskBId -Status interrupted -Message 'Synthetic task B is idle.' -ConfigPath $schedulerConfigPath | Out-Null
$leaseARestored = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskAId -ConfigPath $schedulerConfigPath
$branchAfterA = ((Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('branch','--show-current')) -join '').Trim()
$taskAText = Get-Content -LiteralPath (Join-Path $schedulerWorkspace 'tracked.txt') -Raw -Encoding UTF8
$taskAUntrackedExists = Test-Path -LiteralPath (Join-Path $schedulerWorkspace 'task-a-untracked.txt') -PathType Leaf
$taskARestoredSession = Get-Content -LiteralPath $taskASessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskBSessionPath = Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskBId\workspace-session.json"
$taskBSuspended = Get-Content -LiteralPath $taskBSessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$leaseARestored.Status -ne 'active' -or $branchAfterA -ne 'feature/task-a' -or $taskAText.Trim() -ne 'task-a' -or -not $taskAUntrackedExists -or -not [string]::IsNullOrWhiteSpace([string]$taskARestoredSession.repositories[0].stashCommit) -or [string]::IsNullOrWhiteSpace([string]$taskBSuspended.repositories[0].stashCommit)) { throw 'Returning to task A did not restore its exact branch and working tree.' }

& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status interrupted -Message 'Synthetic task A yields the lease.' -ConfigPath $schedulerConfigPath | Out-Null
$leaseBRestored = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskBId -ConfigPath $schedulerConfigPath
$branchAfterBRestore = ((Invoke-SchedulerTestGit -Workspace $schedulerWorkspace -Arguments @('branch','--show-current')) -join '').Trim()
$taskBText = Get-Content -LiteralPath (Join-Path $schedulerWorkspace 'tracked.txt') -Raw -Encoding UTF8
if ([string]$leaseBRestored.Status -ne 'active' -or $branchAfterBRestore -ne 'feature/task-b' -or $taskBText.Trim() -ne 'task-b' -or -not (Test-Path -LiteralPath (Join-Path $schedulerWorkspace 'task-b-untracked.txt') -PathType Leaf)) { throw 'Returning to task B did not restore its exact branch and working tree.' }

& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskBId -Status running -Message 'Synthetic task B owns the workspace.' -ConfigPath $schedulerConfigPath | Out-Null
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskCId -TaskSelector synthetic-workspace-c -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
$queuedC = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskCId -ConfigPath $schedulerConfigPath
$taskC = Get-Content -LiteralPath (Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskCId\task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$queuedC.Status -ne 'queued' -or [string]$taskC.status -ne 'queued') { throw 'A second task was not queued while another task owned the workspace lease.' }
Add-Check -Name 'serialized-workspace-scheduler' -Detail 'One task owns the workspace; later tasks queue; task branches and tracked/untracked changes survive task-specific stash/restore'

$requirementsPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\requirements-analyst.md') -Raw -Encoding UTF8
foreach ($excludedTree in @('node_modules','.nuget','vendor','bin','obj','dist','coverage')) {
    if ($requirementsPrompt -notmatch [regex]::Escape($excludedTree)) { throw ('Requirements Analyst first-party boundary is missing exclusion: ' + $excludedTree) }
}
if ($requirementsPrompt -notmatch 'first-party source code' -or $requirementsPrompt -notmatch 'Do not inspect the dependency') { throw 'Requirements Analyst must not analyze third-party dependency implementation.' }
Add-Check -Name 'requirements-first-party-boundary' -Detail 'Requirements Analyst excludes dependency implementations, caches, vendor trees, and generated output'

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.workflow.orchestration.enabled -or [string]$config.workflow.orchestration.agentId -ne 'orchestrator' -or [string]$config.workflow.orchestration.fallbackAgentId -ne 'requirements_analyst') { throw 'Workflow Orchestrator configuration is incomplete.' }
$orchestratorAgent = @($config.agents | Where-Object id -eq 'orchestrator') | Select-Object -First 1
if (-not $orchestratorAgent -or @($orchestratorAgent.responsibilities).Count -lt 3) { throw 'Orchestrator responsibilities are not defined in the canonical agent directory.' }
if ([int]$config.ui.agentLogRefreshSeconds -ne 30) { throw 'Default ui.agentLogRefreshSeconds must be 30.' }
if ([int]$config.runtime.contextLimits.maxSourceFiles -gt 100 -or [int]$config.runtime.contextLimits.maxCommandOutputBytes -gt 65536) { throw 'Default AI context limits are too broad.' }
if ([int]$config.review.maxFilesPerReview -gt 80 -or [int]$config.review.maxDiffCharacters -gt 500000) { throw 'Default PR review model-input limits are too broad.' }
$pipelineAgent = @($config.agents | Where-Object id -eq 'pipeline_monitor') | Select-Object -First 1
if ([string]$pipelineAgent.reasoningEffort -ne 'low') { throw 'Pipeline Monitor must use low reasoning effort for deterministic monitoring.' }
$pipelinePrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\pipeline-monitor.md') -Raw -Encoding UTF8
if ($pipelinePrompt -notmatch 'Refresh-TaskPipelineResult.ps1' -or $pipelinePrompt -notmatch 'Pull-request creation is never a prerequisite' -or $pipelinePrompt -notmatch 'older in-progress retry must not hide a newer terminal run') { throw 'Pipeline Monitor targeted restart must refresh the newest exact-SHA logs before PR synchronization.' }
$pipelineRefreshScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Refresh-TaskPipelineResult.ps1') -Raw -Encoding UTF8
if ($pipelineRefreshScript -notmatch '\$commitExitCode\s*=\s*\$LASTEXITCODE' -or $pipelineRefreshScript -notmatch '\$remoteCommitExitCode\s*=\s*\$LASTEXITCODE' -or $pipelineRefreshScript -match 'if\s*\(\$LASTEXITCODE\s+-ne\s+0\s+-or\s+\$Commit') { throw 'Pipeline refresh must not read an unset LASTEXITCODE when Branch or Commit is supplied explicitly.' }
Add-Check -Name 'pipeline-refresh-explicit-commit' -Detail 'Explicit branch and commit refresh validates values without reading a stale or unset LASTEXITCODE'
$pipelineWatcherScript = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Raw -Encoding UTF8
if ($pipelineWatcherScript -notmatch 'azdo-.*NewGuid' -or $pipelineWatcherScript -notmatch 'finally\s*\{\s*if\s*\(Test-Path -LiteralPath \$logFile') { throw 'Pipeline failed-log retrieval must use a unique non-existing temp path and guarantee cleanup.' }
Add-Check -Name 'pipeline-log-temp-files' -Detail 'Every Azure failed-log download uses a unique path and removes it after bounded extraction'
if (-not [bool]$config.pipeline.postPush.enabled -or [int]$config.pipeline.postPush.maxRemediationCycles -ne 3 -or [int]$config.pipeline.postPush.activityHeartbeatSeconds -ne 60) { throw 'Post-push monitoring must be enabled with a 60-second activity heartbeat and three-cycle remediation ceiling.' }
if (-not [bool]$config.workflow.automaticContinuation.enabled -or [int]$config.workflow.automaticContinuation.maxChainSteps -ne 16 -or [int]$config.workflow.automaticContinuation.maxTransitionRepeats -ne 3 -or -not [bool]$config.workflow.automaticContinuation.useElevatedExecution) { throw 'Automatic targeted continuation configuration is incomplete.' }
if (-not [bool]$config.pipeline.delivery.autoPushAfterCleanReview -or [bool]$config.pipeline.delivery.allowForce -or [bool]$config.pipeline.delivery.allowTags -or [int]$config.pipeline.pullRequests.pollIntervalMinutes -ne 120) { throw 'Guarded delivery or two-hour PR lifecycle polling configuration is invalid.' }
if ([bool]$config.review.excludeSelfAuthored) { throw 'Review Monitor must include PRs authored by the configured reviewer as well as assigned PRs.' }
$excelPipeline = @($config.pipeline.repositories | Where-Object repositoryId -eq 'azure-planningspace-ps-excel-agent') | Select-Object -First 1
if ((@($excelPipeline.autoQueueDefinitionIds) -join ',') -ne '814,892' -or @($config.pipeline.repositories.autoQueueDefinitionIds) -contains 891) { throw 'Approved build definitions must be ordered 814 then 892; deployment 891 is forbidden.' }
Add-Check -Name 'configuration-semantics' -Detail "mode=$($config.operation.mode); repositories=$(@($config.repositories).Count); agents=$(@($config.agents).Count)"

$pipelineTestRoot = Join-Path $OutputRoot 'pipeline-monitor'
New-Item -ItemType Directory -Path $pipelineTestRoot -Force | Out-Null
$pipelineResultPath = Join-Path $pipelineTestRoot 'pipeline-result.json'
$pipelineTestTaskId = 'pipeline-test-' + [guid]::NewGuid().ToString('N')
$pipelineProgressStages = [Collections.Generic.List[string]]::new()
$pipelineProgressCallback = { param($Stage, $Summary, $Details) $pipelineProgressStages.Add([string]$Stage) }.GetNewClosure()
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $pipelineResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -DefinitionIds 892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $pipelineResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -RemediationCycle 0 -MaxRemediationCycles 3 -ProgressHeartbeatSeconds 1 -ProgressCallback $pipelineProgressCallback -PassThru
}
finally { Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue }
if ([string]$pipelineResult.overallResult -ne 'non-success' -or [string]$pipelineResult.failureClassification.category -ne 'code' -or [string]$pipelineResult.remediation.status -ne 'pending' -or [string]$pipelineResult.remediation.targetAgentId -ne 'developer' -or [int]$pipelineResult.remediation.cycle -ne 1) { throw 'Synthetic exact-SHA code failure was not classified and routed to Developer.' }
if (-not (Test-Path -LiteralPath $pipelineResultPath -PathType Leaf) -or (Get-Content -LiteralPath $pipelineResultPath -Raw | ConvertFrom-Json).commit -ne '0123456789abcdef0123456789abcdef01234567') { throw 'Structured pipeline-result.json was not persisted for the exact commit.' }
if (@($pipelineProgressStages) -notcontains 'pipeline_discovery' -or @($pipelineProgressStages) -notcontains 'pipeline_waiting' -or @($pipelineProgressStages) -notcontains 'pipeline_failure_analysis' -or @($pipelineProgressStages) -notcontains 'pipeline_terminal') { throw 'Pipeline native watcher did not publish the required dashboard stages.' }
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
$latestResultPath = Join-Path $pipelineTestRoot 'latest-terminal-result.json'
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'latest-terminal'
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $latestResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-5)) -PollSeconds 0 -DiscoveryTimeoutMinutes 0 -RunTimeoutMinutes 1 -LatestRunPerDefinition -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $latestResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -PassThru
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
if (@($latestResult.runs).Count -ne 1 -or [int]$latestResult.runs[0].id -ne 99002 -or [string]$latestResult.overallResult -ne 'non-success') { throw 'Targeted refresh did not select the newest terminal run per definition.' }
Add-Check -Name 'pipeline-targeted-refresh' -Detail 'Newest terminal exact-SHA run is analyzed even when an older retry remains in progress'
$infrastructureClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Publish image' -LogLines 'service connection authentication failed'
if ([string]$infrastructureClassification.category -ne 'infrastructure' -or [bool]$infrastructureClassification.developerEligible) { throw 'Infrastructure failure must not be routed to Developer.' }
$certificateClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Sign Excel Agent binaries' -LogLines 'Signing failed with error 800B010A (CERT_E_CHAINING).'
if ([string]$certificateClassification.category -ne 'infrastructure' -or [bool]$certificateClassification.developerEligible) { throw 'Certificate-chain signing failures must be classified as infrastructure and must not route to Developer.' }
$yamlClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Validate azure-pipelines.yml' -LogLines 'YAML syntax parse error: did not find expected key'
if ([string]$yamlClassification.category -ne 'code' -or -not [bool]$yamlClassification.developerEligible) { throw 'YAML pipeline configuration failures must route to Developer.' }
$excelValidationWrapperClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Validate and stage Excel workbook add-in package' -LogLines @('Validated Main-bck.xlsm: HASH','Validated Main.xlsx: HASH','Validated PlanningSpaceExcelAddIn.xlam: HASH','Excel deliverable validation failed with exit code .','PowerShell exited with code ''1''.')
if ([string]$excelValidationWrapperClassification.category -ne 'code' -or -not [bool]$excelValidationWrapperClassification.developerEligible -or @($excelValidationWrapperClassification.matchedSignals) -notcontains 'Excel deliverable validation failed with exit code .') { throw 'The invalid PowerShell LASTEXITCODE wrapper signal must be classified as pipeline code and routed to Developer.' }
Add-Check -Name 'excel-validation-wrapper-classification' -Detail 'A successful Excel artifact validation followed by an empty LASTEXITCODE wrapper failure routes the YAML defect to Developer'
$officeSipProbeClassification = & (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -TaskNames 'Prove Office SIP cleanup after a controlled failure' -LogLines 'The hosted Office SIP failure-cleanup probe did not observe the expected controlled failure. Office SIP registration did not activate the expected OOXML subject GUID. The job-created Office SIP registry state remained after cleanup.'
if ([string]$officeSipProbeClassification.category -ne 'test' -or -not [bool]$officeSipProbeClassification.developerEligible) { throw 'The controlled Office SIP activation/cleanup probe failure must route to Developer.' }
Add-Check -Name 'office-sip-probe-classification' -Detail 'A failed controlled Office SIP activation/cleanup proof is classified as a Developer-eligible test failure'
$pipelineTestConfigPath = Join-Path $pipelineTestRoot 'agents.json'
$pipelineTestConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pipelineTestConfig.runtime.stateRoot = (Join-Path $pipelineTestRoot 'state')
Write-Utf8NoBom -Path $pipelineTestConfigPath -Content (($pipelineTestConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$pipelineTestTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $pipelineTestTaskId -TaskSelector synthetic-pipeline-test -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $pipelineTestConfigPath
$firstRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$duplicateRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$pipelineTaskState = Get-Content -LiteralPath $pipelineTestTask.TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [bool]$firstRemediation.Requested -or [bool]$duplicateRemediation.Requested -or [string]$pipelineTaskState.status -ne 'interrupted' -or [string]$pipelineTaskState.agentStatuses.developer.status -ne 'pending' -or -not (Test-Path -LiteralPath $firstRemediation.Artifact -PathType Leaf)) { throw 'Developer pipeline remediation request was not persisted, targeted, deduplicated, or projected as unfinished task work.' }
Add-Check -Name 'post-push-pipeline-remediation' -Detail 'Exact-SHA run, bounded code/test classification, Developer routing, infrastructure exclusion, and three-cycle ceiling'

$lifecycleTaskId = 'pr-lifecycle-test-' + [guid]::NewGuid().ToString('N')
$lifecycleTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $lifecycleTaskId -TaskSelector synthetic-pr-lifecycle -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $pipelineTestConfigPath
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'delivery-result.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; repositoryId='azure-planningspace-ps-excel-agent'; branch='feature/synthetic-pr'; commit='0123456789abcdef0123456789abcdef01234567' } | ConvertTo-Json) + [Environment]::NewLine)
$activePrPath = Join-Path $pipelineTestRoot 'active-pr.json'
$activePrPayload = @(
    [ordered]@{ pullRequestId=122; status='active'; title='Incomplete unrelated object' },
    [ordered]@{ pullRequestId=123; status='active'; sourceRefName='refs/heads/feature/synthetic-pr'; title='Synthetic'; creationDate='2026-08-10T00:00:00Z'; createdBy=[ordered]@{ displayName='Test User' } }
)
Write-Utf8NoBom -Path $activePrPath -Content ((ConvertTo-Json -InputObject $activePrPayload -Depth 8) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $lifecycleTaskId -Status review_pending -Stage review_decision_required -Message 'Synthetic unresolved review gate.' -ConfigPath $pipelineTestConfigPath | Out-Null
$gatedSync = & (Join-Path $root 'scripts\Sync-TaskPullRequestStatus.ps1') -TaskId $lifecycleTaskId -RepositoryId azure-planningspace-ps-excel-agent -PullRequestsJsonPath $activePrPath -DoNotStartKnowledgeUpdate -ConfigPath $pipelineTestConfigPath
if ([string]$gatedSync.Status -ne 'task-gated' -or (Test-Path -LiteralPath (Join-Path $lifecycleTask.TaskRoot 'pull-request-status.json'))) { throw 'PR lifecycle synchronization overwrote an unresolved human-review gate.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $lifecycleTaskId -Status created -Stage created -Message 'Synthetic review gate cleared.' -ConfigPath $pipelineTestConfigPath | Out-Null
$activeSync = & (Join-Path $root 'scripts\Sync-TaskPullRequestStatus.ps1') -TaskId $lifecycleTaskId -RepositoryId azure-planningspace-ps-excel-agent -PullRequestsJsonPath $activePrPath -DoNotStartKnowledgeUpdate -ConfigPath $pipelineTestConfigPath
if ([string]$activeSync.Status -ne 'waiting' -or [string]$activeSync.Result.status -ne 'active') { throw 'Active PR lifecycle status did not keep the task waiting.' }
$completedPrPath = Join-Path $pipelineTestRoot 'completed-pr.json'
Write-Utf8NoBom -Path $completedPrPath -Content ((@([ordered]@{ pullRequestId=123; status='completed'; sourceRefName='refs/heads/feature/synthetic-pr'; title='Synthetic'; creationDate='2026-08-10T00:00:00Z'; createdBy=[ordered]@{ displayName='Test User' } }) | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$completedSync = & (Join-Path $root 'scripts\Sync-TaskPullRequestStatus.ps1') -TaskId $lifecycleTaskId -RepositoryId azure-planningspace-ps-excel-agent -PullRequestsJsonPath $completedPrPath -DoNotStartKnowledgeUpdate -ConfigPath $pipelineTestConfigPath
if ([string]$completedSync.Status -ne 'completion-requested' -or [string]$completedSync.Closure.TargetAgentId -ne 'orchestrator' -or -not (Test-Path -LiteralPath (Join-Path $lifecycleTask.TaskRoot 'task-closure.json'))) { throw 'Completed PR did not request Orchestrator-owned finalization routing.' }
$orchestratorClosureBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $lifecycleTaskId -AgentId orchestrator -ConfigPath $pipelineTestConfigPath
$keeperClosureBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $lifecycleTaskId -AgentId knowledge_keeper -ConfigPath $pipelineTestConfigPath
if ([int]$orchestratorClosureBatch.count -ne 1 -or [int]$keeperClosureBatch.count -ne 0) { throw 'Completed PR closure input must reach Orchestrator before Knowledge Keeper.' }
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'pipeline-result.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; overallResult='succeeded'; runs=@([ordered]@{ id=1; result='succeeded' }) } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $lifecycleTaskId -AgentId pipeline_monitor -AgentStatus completed -Stage pipeline_complete -Message 'Synthetic pipeline completed.' -ConfigPath $pipelineTestConfigPath | Out-Null
$pipelineContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $lifecycleTaskId -CompletedAgentId pipeline_monitor -PrepareOnly -ConfigPath $pipelineTestConfigPath
if ([string]$pipelineContinuation.Status -ne 'prepared' -or [string]$pipelineContinuation.NextAgentId -ne 'orchestrator') { throw 'Completed Pipeline Monitor must hand terminal PR evidence to Orchestrator.' }
$closureInput = @($orchestratorClosureBatch.comments) | Select-Object -First 1
& (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $lifecycleTaskId -SourceEventId ([string]$closureInput.eventId) -TargetAgentIds knowledge_keeper -Rationale 'Terminal build and completed PR evidence validated; final publication belongs to Knowledge Keeper.' -Confidence high -ConfigPath $pipelineTestConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $lifecycleTaskId -AgentId orchestrator -AgentStatus completed -Stage orchestration_complete -Message 'Synthetic closure route completed.' -ConfigPath $pipelineTestConfigPath | Out-Null
$orchestratorContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $lifecycleTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $pipelineTestConfigPath
if ([string]$orchestratorContinuation.Status -ne 'prepared' -or [string]$orchestratorContinuation.NextAgentId -ne 'knowledge_keeper') { throw 'Knowledge Keeper must start only after Orchestrator persists the final-publication route.' }
Add-Check -Name 'pull-request-lifecycle' -Detail 'Azure PR status is normalized safely; completed PR routes Pipeline Monitor to Orchestrator, then a persisted decision dispatches final Knowledge Keeper publication'

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

$processReviewTaskId = "process-review-$deliveryFixtureId"
$processReviewTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$processReviewTaskId"
New-Item -ItemType Directory -Path $processReviewTaskRoot -Force | Out-Null
$processReviewTask = [ordered]@{
    taskId = $processReviewTaskId
    selector = 'synthetic-process-review'
    mode = 'manual'
    status = 'review_pending'
    repositoryId = $deliveryRepositoryId
    agentStatuses = [ordered]@{ reviewer = [ordered]@{ status = 'completed' } }
}
$processReviewResult = [ordered]@{
    findings = @()
    heldScopeViolations = @()
    agentProcessFindings = @([ordered]@{ id='REV-001'; severity='low'; category='agent-process'; disposition='proposed' })
}
Write-Utf8NoBom -Path (Join-Path $processReviewTaskRoot 'task.json') -Content (($processReviewTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $processReviewTaskRoot 'review-result.json') -Content (($processReviewResult | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$processReviewContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $processReviewTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$processReviewContinuation.Status -ne 'prepared' -or [string]$processReviewContinuation.NextAgentId -ne 'pipeline_monitor') { throw 'A process-only Reviewer suggestion incorrectly blocks Pipeline Monitor continuation.' }
Add-Check -Name 'process-suggestion-continuation' -Detail 'A clean product review continues to Pipeline Monitor while process suggestions remain visible and non-blocking'

$bypassTaskId = "review-bypass-$deliveryFixtureId"
$bypassTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$bypassTaskId"
New-Item -ItemType Directory -Path $bypassTaskRoot -Force | Out-Null
$bypassTask = [ordered]@{
    taskId=$bypassTaskId; selector='synthetic-review-bypass'; mode='manual'; status='review_pending'; repositoryId=$deliveryRepositoryId
    agentStatuses=[ordered]@{ reviewer=[ordered]@{ status='completed' }; pipeline_monitor=[ordered]@{ status='pending' } }
}
$bypassFinding = [ordered]@{
    id='REV-201'; severity='medium'; category='maintainability'; location='sample.ps1:1'
    evidence='Synthetic evidence.'; impact='Synthetic debt impact.'; correctionDirection='Resolve the synthetic debt.'; decisionStatus='proposed'
}
$bypassReview = [ordered]@{ findings=@($bypassFinding); agentProcessFindings=@(); heldScopeViolations=@() }
Write-Utf8NoBom -Path (Join-Path $bypassTaskRoot 'task.json') -Content (($bypassTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $bypassTaskRoot 'review-result.json') -Content (($bypassReview | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$bypassDecision = & (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $bypassTaskId -FindingId REV-201 -Decision bypassed -DecidedBy user -Note 'Accepted as tracked technical debt.' -ConfigPath $deliveryConfigPath
$bypassDebt = Get-Content -LiteralPath (Join-Path $bypassTaskRoot 'tech-debt-items.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bypassContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $bypassTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
$bypassDeliveryPlan = & (Join-Path $root 'scripts\Invoke-ReviewedBranchDelivery.ps1') -TaskId $bypassTaskId -RepositoryId $deliveryRepositoryId -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$bypassDecision.decision -ne 'bypassed' -or [string]$bypassDecision.techDebtItemId -ne 'TD-REV-201' -or @($bypassDebt.items | Where-Object { [string]$_.sourceFindingId -eq 'REV-201' -and [string]$_.status -eq 'open' }).Count -ne 1 -or [string]$bypassContinuation.NextAgentId -ne 'pipeline_monitor' -or [string]$bypassDeliveryPlan.repositoryId -ne $deliveryRepositoryId) { throw 'A bypassed Reviewer finding did not create linked open debt and release only the Pipeline Monitor gate.' }
Add-Check -Name 'review-bypass-technical-debt' -Detail 'Explicit bypass preserves the finding, creates idempotent task-local debt, and permits guarded Pipeline Monitor delivery'

$chainMatrixRoot = Join-Path $deliveryConfig.runtime.stateRoot ('tasks\chain-matrix-' + $deliveryFixtureId)
New-Item -ItemType Directory -Path $chainMatrixRoot -Force | Out-Null
$chainMatrixTaskId = Split-Path -Leaf $chainMatrixRoot
$chainMatrixTask = [ordered]@{
    taskId = $chainMatrixTaskId
    selector = 'synthetic-chain-matrix'
    mode = 'manual'
    status = 'review_pending'
    repositoryId = $deliveryRepositoryId
    agentStatuses = [ordered]@{
        requirements_analyst = [ordered]@{ status = 'completed' }
        developer = [ordered]@{ status = 'completed' }
        reviewer = [ordered]@{ status = 'pending' }
        pipeline_monitor = [ordered]@{ status = 'pending' }
        knowledge_keeper = [ordered]@{ status = 'pending' }
    }
}
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$developerToReviewer = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId developer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$developerToReviewer.Status -ne 'prepared' -or [string]$developerToReviewer.NextAgentId -ne 'reviewer') { throw 'Developer completion at review_pending did not schedule Reviewer.' }

$chainMatrixTask.status = 'interrupted'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$requirementsToDeveloper = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId requirements_analyst -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$requirementsToDeveloper.Status -ne 'prepared' -or [string]$requirementsToDeveloper.NextAgentId -ne 'developer') { throw 'Requirements Analyst completion did not schedule Developer.' }

$continuationLockPath = Join-Path $chainMatrixRoot 'automatic-continuation.lock'
$continuationLock = [IO.File]::Open($continuationLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { $busyContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId requirements_analyst -PrepareOnly -ConfigPath $deliveryConfigPath }
finally { $continuationLock.Dispose() }
if ([string]$busyContinuation.Status -ne 'busy') { throw 'Concurrent continuation ownership did not fail closed.' }

$chainMatrixTask.status = 'waiting_for_input'
$chainMatrixTask.agentStatuses.pipeline_monitor.status = 'completed'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$pipelineRemediation = [ordered]@{ overallResult = 'failed'; remediation = [ordered]@{ targetAgentId = 'developer'; status = 'pending' } }
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'pipeline-result.json') -Content (($pipelineRemediation | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$pipelineToDeveloper = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId pipeline_monitor -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$pipelineToDeveloper.Status -ne 'prepared' -or [string]$pipelineToDeveloper.NextAgentId -ne 'developer') { throw 'Pipeline code or test remediation did not schedule Developer from a waiting task gate.' }

$chainMatrixTask.status = 'interrupted'
$chainMatrixTask.agentStatuses.knowledge_keeper.status = 'completed'
$chainMatrixTask.agentStatuses.reviewer.status = 'pending'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$keeperToUnfinished = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId knowledge_keeper -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$keeperToUnfinished.Status -ne 'prepared' -or [string]$keeperToUnfinished.NextAgentId -ne 'reviewer') { throw 'Scoped Knowledge Keeper completion did not return to the first unfinished delivery role.' }

$chainMatrixTask.status = 'interrupted'
$chainMatrixTask.agentStatuses.orchestrator = [ordered]@{ status = 'completed' }
$chainMatrixTask.agentStatuses.requirements_analyst.status = 'pending'
$chainMatrixTask.agentStatuses.developer.status = 'pending'
$chainMatrixTask.agentStatuses.reviewer.status = 'pending'
$chainMatrixTask.agentStatuses.pipeline_monitor.status = 'pending'
$chainMatrixTask.agentStatuses.knowledge_keeper.status = 'pending'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$orchestratorToRequirements = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$orchestratorToRequirements.Status -ne 'prepared' -or [string]$orchestratorToRequirements.NextAgentId -ne 'requirements_analyst') { throw 'Initial or resumed Orchestrator completion did not schedule the first pending delivery role.' }

$chainMatrixTask.status = 'waiting_for_input'
$chainMatrixTask.agentStatuses.reviewer.status = 'waiting'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$reviewerHumanGate = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$reviewerHumanGate.Status -ne 'waiting') { throw 'Reviewer human-decision gate was misclassified as a failed or abnormal chain stop.' }

$approvedHandoffTaskId = 'approved-handoff-' + $deliveryFixtureId
$approvedHandoffRoot = Join-Path $deliveryConfig.runtime.stateRoot ('tasks\' + $approvedHandoffTaskId)
New-Item -ItemType Directory -Path $approvedHandoffRoot -Force | Out-Null
$approvedHandoffTask = [ordered]@{ taskId=$approvedHandoffTaskId; selector='synthetic-approved-handoff'; mode='manual'; status='review_pending'; repositoryId=$deliveryRepositoryId; agentStatuses=[ordered]@{ reviewer=[ordered]@{ status='completed' }; developer=[ordered]@{ status='completed' }; orchestrator=[ordered]@{ status='completed' } } }
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'task.json') -Content (($approvedHandoffTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedReview = [ordered]@{ findings=@([ordered]@{ id='REV-101'; correctionDirection='Implement approved product coverage.' }); agentProcessFindings=@([ordered]@{ id='REV-102'; correctionDirection='Repair approved workflow fingerprints.' }); heldScopeViolations=@() }
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'review-result.json') -Content (($approvedReview | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedDecisions = [ordered]@{ taskId=$approvedHandoffTaskId; decisions=@([ordered]@{ findingId='REV-101'; decision='approved' },[ordered]@{ findingId='REV-102'; decision='approved' }) }
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'review-decisions.json') -Content (($approvedDecisions | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedHandoff = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $approvedHandoffTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
$approvedDeveloperBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $approvedHandoffTaskId -AgentId developer -ConfigPath $deliveryConfigPath
$approvedOrchestratorBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $approvedHandoffTaskId -AgentId orchestrator -ConfigPath $deliveryConfigPath
if ([string]$approvedHandoff.NextAgentId -ne 'developer' -or @($approvedDeveloperBatch.comments | Where-Object { @($_.evidence) -contains 'review-finding:REV-101' -and @($_.evidence) -contains 'decision:approved' -and [string]$_.text -match 'Implement approved product coverage' }).Count -ne 1 -or @($approvedOrchestratorBatch.comments | Where-Object { @($_.evidence) -contains 'review-finding:REV-102' -and @($_.evidence) -contains 'decision:approved' -and [string]$_.text -match 'Repair approved workflow fingerprints' }).Count -ne 1) { throw 'Approved product and process findings were not durably routed with their correction direction.' }
$approvedHandoffTask = Get-Content -LiteralPath (Join-Path $approvedHandoffRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$approvedHandoffTask.agentStatuses.developer.status = 'completed'
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'task.json') -Content (($approvedHandoffTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedProcessPriority = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $approvedHandoffTaskId -CompletedAgentId developer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$approvedProcessPriority.NextAgentId -ne 'orchestrator') { throw 'An approved process workflow input did not prioritize Orchestrator before the normal post-Developer Reviewer transition.' }
Add-Check -Name 'automatic-chain-transition-matrix' -Detail 'Requirements to Developer, Developer to Reviewer, Pipeline remediation to Developer, and scoped Knowledge Keeper return are host-driven across valid task gates'

$orphanTaskId = 'orphan-continuation-' + $deliveryFixtureId
$orphanRoot = Join-Path $deliveryConfig.runtime.stateRoot ('tasks\' + $orphanTaskId)
New-Item -ItemType Directory -Path $orphanRoot -Force | Out-Null
$orphanTask = [ordered]@{ taskId=$orphanTaskId; selector='synthetic-orphan-continuation'; mode='manual'; status='interrupted'; repositoryId=$deliveryRepositoryId; agentStatuses=[ordered]@{ requirements_analyst=[ordered]@{ status='completed' }; developer=[ordered]@{ status='completed' }; reviewer=[ordered]@{ status='completed' }; pipeline_monitor=[ordered]@{ status='completed' }; knowledge_keeper=[ordered]@{ status='completed' } } }
Write-Utf8NoBom -Path (Join-Path $orphanRoot 'task.json') -Content (($orphanTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$orphanRequestId = [guid]::NewGuid().ToString('N')
$orphanTime = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
$orphanEvents = @(
    [ordered]@{ eventId=$orphanRequestId; taskId=$orphanTaskId; timestampUtc=$orphanTime; actor='ecosystem'; type='continuation-requested'; summary='Synthetic durable continuation request.'; artifact=$null; evidence=@('continuation-request:synthetic','completed-agent:requirements_analyst'); targetAgentId=$null },
    [ordered]@{ eventId=[guid]::NewGuid().ToString('N'); taskId=$orphanTaskId; timestampUtc=[DateTime]::UtcNow.AddMinutes(-4).ToString('o'); actor='requirements_analyst'; type='agent-result'; summary='Synthetic published outcome.'; artifact=$null; evidence=@("continuation-event:$orphanRequestId"); targetAgentId=$null }
)
Write-Utf8NoBom -Path (Join-Path $orphanRoot 'task-ledger.jsonl') -Content ((@($orphanEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join [Environment]::NewLine) + [Environment]::NewLine)
$orphanRecovery = & (Join-Path $root 'scripts\Repair-AgentContinuations.ps1') -TaskId $orphanTaskId -ConfigPath $deliveryConfigPath
if (@($orphanRecovery.Items | Where-Object { [string]$_.Status -eq 'continuation-required' -and [string]$_.CompletedAgentId -eq 'requirements_analyst' }).Count -ne 1) { throw 'Durable continuation recovery did not detect a published outcome whose host exited before handoff.' }
Add-Check -Name 'durable-continuation-recovery' -Detail 'A completed outcome without a live host or downstream scheduling event is detected once; per-task locking prevents duplicate dispatch'

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
$orchestratorPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\orchestrator.md') -Raw -Encoding UTF8
$healthPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\health-check.md') -Raw -Encoding UTF8
$resumeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -Raw -Encoding UTF8
$healthRecoveryScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentHealthRecovery.ps1') -Raw -Encoding UTF8
$healthTargetedResumeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-HealthTargetedResume.ps1') -Raw -Encoding UTF8
$continueChainScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Continue-AgentChain.ps1') -Raw -Encoding UTF8
$continuationRecoveryScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Repair-AgentContinuations.ps1') -Raw -Encoding UTF8
$publishOutcomeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -Raw -Encoding UTF8
$healthRecoverySchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\health-recovery-result.schema.json') -Raw -Encoding UTF8
if ($knowledgePrompt -notmatch 'Never cyclically poll' -or $knowledgePrompt -notmatch 'explicit agent knowledge or skill requests') { throw 'Knowledge Keeper is not pull-based or still permits subagent polling.' }
if ($taskProtocol -notmatch 'Publish-AgentOutcome.ps1' -or $taskProtocol -notmatch 'agent-checkpoints' -or $taskProtocol -notmatch 'autonomous bounded work blocks' -or $taskProtocol -notmatch 'Get-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Acknowledge-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Request-OrchestratorCommentRouting.ps1' -or $taskProtocol -notmatch 'same agent invocation') { throw 'Private checkpoint, autonomous work-block, successful outcome, end-of-block comment, or authority-handoff contract is missing.' }
if (-not [bool]$config.workflow.orchestration.forwardOutOfScopeComments -or -not [bool]$config.workflow.orchestration.autoDispatchForwardedComments -or $continueChainScript -notmatch 'agent-routing-request' -or $continueChainScript -notmatch 'workflow-input-routed') { throw 'Automatic out-of-scope and approved-process input routing is not enabled end to end.' }
if ($continueChainScript -notmatch 'reevaluateDeveloperGate' -or $continueChainScript -notmatch 'reevaluatePipelineGate') { throw 'Developer review continuation or Pipeline remediation continuation is blocked by a stale task gate.' }
if ($continueChainScript -notmatch 'transitionCounts' -or $continueChainScript -notmatch 'maxTransitionRepeats' -or $continueChainScript -notmatch 'automatic_chain_guard' -or $continueChainScript -notmatch 'Start-AgentHealthRecovery.ps1') { throw 'Automatic continuation loop limits do not fail closed into Health Check.' }
if ($continueChainScript -notmatch 'pipeline_authority_handoff' -or $workflowScript -notmatch 'preservePipelineNonSuccess') { throw 'A non-success pipeline can still close the task or fail to hand unknown ownership to Orchestrator.' }
if ($continueChainScript -notmatch 'automatic-continuation\.lock' -or $publishOutcomeScript -notmatch 'continuation-requested' -or $continuationRecoveryScript -notmatch 'continuation-reconciled' -or $continuationRecoveryScript -notmatch 'recoveryGraceSeconds') { throw 'Durable, idempotent continuation recovery is incomplete.' }
if ($dashboardHtml -notmatch 'finishing its current work block' -or $dashboardClient -notmatch 'no restart is needed') { throw 'Dashboard does not explain automatic end-of-block comment consumption.' }
if ($healthPrompt -notmatch 'health-diagnostic-context.json' -or $healthRecoveryScript -notmatch 'Get-BoundedTextTail' -or $healthRecoveryScript -notmatch 'workflowLogTailLines') { throw 'Health Check bounded diagnostic context is incomplete.' }
if ($healthPrompt -notmatch 'diagnosis is not a terminal outcome' -or $healthRecoveryScript -notmatch 'existingDiagnosis' -or $healthRecoveryScript -notmatch 'health-repair-routing.json' -or $healthRecoverySchema -notmatch 'routeAgentId' -or $healthRecoverySchema -notmatch 'repairOwner') { throw 'Health Check repair-or-route contract is incomplete.' }
if ($orchestratorPrompt -notmatch 'explicit source-controlled ecosystem maintenance go to health_check' -or $orchestratorPrompt -notmatch 'Do not ask to expand a product task for Developer' -or $healthPrompt -notmatch 'explicit source-controlled ecosystem change' -or $healthPrompt -notmatch 'Do not redirect ecosystem source changes to Developer') { throw 'Ecosystem source maintenance is not owned end to end by Health Check.' }
if ($workflowScript -notmatch 'health_recovery_handoff' -or $workflowScript -notmatch 'DiagnosisPath' -or $workflowScript -notmatch 'repairOwner' -or $workflowScript -notmatch 'requiresUserInput' -or $workflowScript -notmatch 'health_diagnosis_recovery') { throw 'A waiting or completed non-user-input Health Check diagnosis is not handed to automatic recovery.' }
if ($continueChainScript -notmatch "PSObject\.Properties\['repositoryIds'\]" -or $continueChainScript -notmatch "PSObject\.Properties\['repositoryId'\]") { throw 'Automatic continuation does not normalize legacy singular repositoryId task scope.' }
if ($healthPrompt -notmatch 'restart exactly the affected agentId' -or $taskProtocol -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Health Check prompt contract does not restrict post-repair execution to the affected agent.' }
if ($healthTargetedResumeScript -notmatch 'TargetAgentId = \$targetAgentId' -or $healthTargetedResumeScript -notmatch 'HealthRecoveryRetry = \$true' -or $healthTargetedResumeScript -notmatch 'maxAttemptsPerFailureSignature' -or $healthTargetedResumeScript -notmatch 'RecoveryEvidencePath') { throw 'Health Check targeted-resume launcher is missing its target, validation, or retry-loop guard.' }
if ($workflowScript -notmatch 'HealthRecoveryRetry' -or $workflowScript -notmatch '-not \$HealthRecoveryRetry' -or $healthRecoveryScript -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Workflow and Health recovery are not wired to the one-shot targeted retry.' }
if ($healthRecoveryScript -notmatch 'RecoveryDepth' -or $healthRecoveryScript -notmatch 'health_recovery_followup' -or $healthRecoveryScript -notmatch 'Write-AgentFailure.ps1' -or $healthRecoveryScript -notmatch "targetedResume.Status -eq 'failed'") { throw 'A failure exposed by post-repair targeted resume is not returned to bounded Health recovery.' }
if ($resumeScript -notmatch 'ChangedArtifactNames' -or $resumeScript -notmatch 'resume-artifact-index.json' -or $resumeScript -notmatch 'shareableArtifacts' -or $resumeScript -notmatch "-ne 'completed'" -or $workflowScript -notmatch 'Get-AgentResumePlan\.ps1.+-PreserveArtifactIndex') { throw 'Resume artifact fingerprinting, completed-outcome filtering, or non-consuming bookkeeping is incomplete.' }

$fingerprintRoot = Join-Path $OutputRoot ('resume-fingerprint-' + [guid]::NewGuid().ToString('N'))
$fingerprintConfigPath = Join-Path $fingerprintRoot 'agents.json'
$fingerprintConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fingerprintConfig.runtime.stateRoot = Join-Path $fingerprintRoot 'state'
Write-Utf8NoBom -Path $fingerprintConfigPath -Content (($fingerprintConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$fingerprintTaskId = 'resume-fingerprint-' + [guid]::NewGuid().ToString('N')
$fingerprintTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $fingerprintTaskId -TaskSelector synthetic-resume-fingerprint -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fingerprintConfigPath
$null = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId developer -ConfigPath $fingerprintConfigPath
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'implementation-plan.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"scope`":[]}$([Environment]::NewLine)"
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'implementation-result.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"status`":`"implemented`"}$([Environment]::NewLine)"
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $fingerprintTaskId -AgentId developer -AgentStatus completed -Stage developer-completed -Message 'Synthetic Developer outcome changed its implementation artifacts.' -ConfigPath $fingerprintConfigPath | Out-Null
$postDeveloperBookkeepingPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -PreserveArtifactIndex -ConfigPath $fingerprintConfigPath
$reviewerStartupPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId reviewer -ConfigPath $fingerprintConfigPath
$reviewerRepeatedPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId reviewer -ConfigPath $fingerprintConfigPath
$developerArtifacts = @('implementation-plan.json','implementation-result.json')
if (@($developerArtifacts | Where-Object { $_ -notin @($postDeveloperBookkeepingPlan.ChangedArtifactNames) }).Count -or @($developerArtifacts | Where-Object { $_ -notin @($reviewerStartupPlan.ChangedArtifactNames) }).Count -or @($developerArtifacts | Where-Object { $_ -notin @($reviewerRepeatedPlan.UnchangedArtifactNames) }).Count) { throw 'Developer-to-Reviewer continuation consumed changed artifact fingerprints during post-Developer bookkeeping.' }
Add-Check -Name 'developer-reviewer-resume-fingerprints' -Detail 'Post-Developer bookkeeping preserves the fingerprint baseline; Reviewer startup receives changed implementation artifacts and then advances the index once'
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
$healthResponsibilities = @($healthAgent.responsibilities) -join [Environment]::NewLine
if ($healthResponsibilities -notmatch 'source-controlled changes to the development-agent ecosystem' -or $healthResponsibilities -notmatch 'bounded ecosystem_recovery plan') { throw 'Health Check canonical responsibilities do not include ecosystem source maintenance.' }
if ((@($config.agents | Where-Object id -eq 'orchestrator' | Select-Object -ExpandProperty responsibilities) -join [Environment]::NewLine) -notmatch 'source-controlled ecosystem scripts') { throw 'Orchestrator role directory does not route ecosystem source maintenance to Health Check.' }
if ([string]$healthAgent.sandboxMode -ne 'read-only') { throw 'Health Check Agent must remain read-only inside product workflows.' }
if ([bool]$config.health.automaticRecovery.allowProductCodeChanges -or [bool]$config.health.automaticRecovery.allowExternalWrites) { throw 'Automatic health recovery boundary is unsafe.' }
if (-not [bool]$config.health.automaticRecovery.commitVerifiedRepairs -or $healthRecoveryScript -notmatch 'health_recovery_commit' -or $healthRecoveryScript -notmatch 'git -C \$workspace commit') { throw 'Validated ecosystem repairs are not committed locally by the trusted host.' }
if ([string]$config.health.automaticRecovery.sandboxMode -ne 'workspace-write') { throw 'Unattended automatic health recovery must remain sandboxed.' }
if ([string]$config.health.automaticRecovery.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Elevated recovery must require explicit dashboard approval.' }
if ($dashboardServer -notmatch 'OperatorApprovedDirtyWorktree=\$true' -or $healthRecoveryScript -notmatch 'preExistingWorktreeChanges') { throw 'Approved elevated Health Check recovery does not preserve and expose the dirty ecosystem baseline.' }
$targetedResumeConfig = $config.health.automaticRecovery.targetedResume
if (-not [bool]$targetedResumeConfig.enabled -or -not [bool]$targetedResumeConfig.requireSuccessfulRepair -or [int]$targetedResumeConfig.maxAttemptsPerFailureSignature -ne 1) { throw 'Health Check targeted resume must require validated repair and permit exactly one attempt.' }
if (@($targetedResumeConfig.allowedAgentIds) -contains 'health_check' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'requirements_analyst' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'developer') { throw 'Health Check targeted resume allowlist is unsafe or incomplete.' }
foreach ($healthScript in @('Invoke-EcosystemHealthCheck.ps1','Write-AgentFailure.ps1','Start-AgentHealthRecovery.ps1','Start-HealthTargetedResume.ps1','Invoke-GuardedCodex.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$healthScript") -PathType Leaf)) { throw "Health recovery script is missing: $healthScript" }
}
Add-Check -Name 'health-recovery-contract' -Detail "automatic=$($config.health.automaticRecovery.enabled); attempts=$($config.health.automaticRecovery.maxAttemptsPerFailureSignature); targetedAttempts=$($targetedResumeConfig.maxAttemptsPerFailureSignature); failedAgentOnly=true; sandbox=workspace-write; elevated=approval-gated; productWrites=false; externalWrites=false"

$guardTestRoot = Join-Path $OutputRoot 'execution-guard'
if (Test-Path -LiteralPath $guardTestRoot) { Remove-Item -LiteralPath $guardTestRoot -Recurse -Force }
New-Item -ItemType Directory -Path $guardTestRoot -Force | Out-Null
$guardTest = & (Join-Path $root 'scripts\Invoke-GuardedCodex.ps1') -FilePath 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tests\fixtures\Emit-RepeatedCodexFailures.ps1')) -Prompt '' -WorkingDirectory $root -LogPath (Join-Path $guardTestRoot 'events.jsonl') -GuardArtifactPath (Join-Path $guardTestRoot 'guard.json') -MaxIdenticalFailures 3 -MaxRunMinutes 1 -PollMilliseconds 100
$guardTemporaryFiles = @(Get-ChildItem -LiteralPath $guardTestRoot -File | Where-Object Name -Match '\.(stdin\.txt|stdout\.tmp)$')
if (-not [bool]$guardTest.guardTriggered -or [int]$guardTest.identicalFailureCount -ne 3 -or [int]$guardTest.exitCode -ne 1 -or [string]$guardTest.reason -notmatch 'retry limit' -or -not (Test-Path -LiteralPath (Join-Path $guardTestRoot 'guard.json') -PathType Leaf) -or $guardTemporaryFiles.Count -ne 0) { throw 'Execution guard did not stop the deterministic repeated-failure fixture after exactly three attempts and clean up redirected temporary files.' }
Add-Check -Name 'execution-retry-guard' -Detail 'Three identical failures stop execution, produce a guard artifact, and release redirected temporary files'

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
$reviewRenderer = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pr-review-monitor\scripts\render_azure_review.ps1') -Raw -Encoding UTF8
if ($reviewWrapper -match 'rerunWhenCommentsChange\s*-and\s*\[bool\]\$comments\.Changed' -or $reviewWrapper -notmatch 'ForceReviewKey') { throw 'A changed PR comment must not become a global ForceReview.' }
if ($commentCollector -notmatch 'ChangedPullRequestKeys' -or $commentCollector -notmatch 'pending-review-changes.json' -or $commentCollector -notmatch 'Get-OptionalPropertyValue' -or $reviewRunner -notmatch 'requires-human-intervention' -or $reviewRenderer -match '\$Source\.Raw') { throw 'Per-PR review invalidation, optional provider fields, and pending human state are incomplete.' }
Add-Check -Name 'review-monitor-config' -Detail $reviewConfig.ConfigPath
Add-Check -Name 'per-pr-review-invalidation' -Detail 'Only the changed PR is forced; unprocessed and failed AI review state remains visible'

[pscustomobject]@{
    Passed = $true
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    Checks = @($checks)
}
