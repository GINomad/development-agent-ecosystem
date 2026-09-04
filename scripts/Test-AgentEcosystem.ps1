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

$syntheticReviewDimensions = @('requirements','correctness','security','regression','testing','maintainability','performance','concurrency','configuration-deployment','documentation')

function New-SyntheticReviewFinding {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][ValidateSet('correctness','security','regression','testing','maintainability','performance','concurrency','configuration-deployment','documentation','requirements','knowledge','agent-process')][string] $Category,
        [Parameter(Mandatory)][string] $CorrectionDirection
    )
    [ordered]@{
        id = $Id
        severity = if ($Category -eq 'agent-process') { 'low' } else { 'medium' }
        category = $Category
        location = 'synthetic.ps1:1'
        evidence = "Synthetic direct evidence for $Id."
        impact = "Synthetic impact for $Id."
        correctionDirection = $CorrectionDirection
        decisionStatus = 'proposed'
    }
}

function New-SyntheticReviewResult {
    param(
        [Parameter(Mandatory)][string] $TaskId,
        [string] $ReviewedRevision = 'synthetic-review-v1',
        [object[]] $ProductFindings = @(),
        [object[]] $ProcessFindings = @()
    )
    [object[]] $activeFindings = @($ProductFindings) + @($ProcessFindings)
    [ordered]@{
        taskId = $TaskId
        reviewedRevision = $ReviewedRevision
        requirementsRevision = 'synthetic-requirements-v1'
        requirementTraceability = @([ordered]@{
            requirementId = 'REQ-SYNTHETIC-1'
            requirementText = 'The synthetic review contract is complete.'
            implementationStatus = 'verified'
            codeReferences = @()
            testEvidence = @('Test-AgentEcosystem.ps1 synthetic fixture')
            notes = 'Synthetic contract evidence.'
        })
        reviewCoverage = @($syntheticReviewDimensions | ForEach-Object {
            [ordered]@{ dimension=$_; status='covered'; evidence=@("Synthetic evidence for $_."); notes="Synthetic $_ coverage." }
        })
        findings = [object[]]@($ProductFindings)
        heldScopeViolations = @()
        agentProcessFindings = [object[]]@($ProcessFindings)
        findingLifecycle = @($activeFindings | ForEach-Object {
            [ordered]@{ findingId=[string]$_.id; status='new'; firstSeenRevision=$ReviewedRevision; lastObservedRevision=$ReviewedRevision; evidence="Synthetic lifecycle evidence for $([string]$_.id)." }
        })
        summary = 'Synthetic complete review result.'
    }
}

function New-SyntheticReviewVerification {
    param(
        [Parameter(Mandatory)][string] $TaskId,
        [Parameter(Mandatory)][string] $ReviewPath,
        [hashtable] $FindingVerdicts = @{}
    )
    $review = Get-Content -LiteralPath $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sha256 = (Get-FileHash -LiteralPath $ReviewPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [object[]] $activeFindings = @($review.findings) + @($review.agentProcessFindings)
    [ordered]@{
        taskId = $TaskId
        reviewedRevision = [string]$review.reviewedRevision
        reviewArtifactSha256 = $sha256
        verificationStatus = 'passed'
        coverageVerification = @($review.reviewCoverage | ForEach-Object {
            [ordered]@{ dimension=[string]$_.dimension; claimedStatus=[string]$_.status; verdict='confirmed'; evidence=@("Independent synthetic evidence for $([string]$_.dimension)."); falsificationAttempts=@("Synthetic falsification of $([string]$_.dimension)."); notes='Claim confirmed independently.' }
        })
        findingVerifications = @($activeFindings | ForEach-Object {
            $id = [string]$_.id
            $verdict = if ($FindingVerdicts.ContainsKey($id)) { [string]$FindingVerdicts[$id] } else { 'confirmed' }
            [ordered]@{ findingId=$id; findingKind=if ([string]$_.category -eq 'agent-process') { 'agent-process' } else { 'product' }; verdict=$verdict; evidence=@("Independent synthetic evidence for $id."); falsificationAttempts=@("Synthetic falsification of $id."); notes='Finding checked independently.' }
        })
        lifecycleVerifications = @($review.findingLifecycle | ForEach-Object {
            [ordered]@{ findingId=[string]$_.findingId; claimedStatus=[string]$_.status; verdict='confirmed'; evidence=@("Independent lifecycle evidence for $([string]$_.findingId)."); notes='Lifecycle checked independently.' }
        })
        summary = 'Synthetic independent review verification passed.'
    }
}

$workflowCliScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
$healthCliScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentHealthRecovery.ps1') -Raw -Encoding UTF8
$healthCheckCliScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-EcosystemHealthCheck.ps1') -Raw -Encoding UTF8
if (-not (Resolve-CodexCliPath) -or $workflowCliScript -notmatch 'Resolve-CodexCliPath' -or $healthCliScript -notmatch 'Resolve-CodexCliPath' -or $healthCheckCliScript -notmatch 'Resolve-CodexCliPath') { throw 'Foreground and scheduled hosts must share the PATH-independent Codex CLI resolver.' }
if ($healthCheckCliScript -notmatch 'Get-AgentDefinitionDrift' -or $healthCheckCliScript -notmatch 'New-AgentToml' -or $healthCheckCliScript -notmatch "reason='outdated'") { throw 'Health Check must detect generated-agent content drift, not only missing files.' }
if ($workflowCliScript -notmatch "'notify=\[\]'" -or $healthCliScript -notmatch "'notify=\[\]'") { throw 'Internal Codex hosts must disable the legacy notify command to avoid Windows command-line overflow on long agent turns.' }
if ($workflowCliScript -notmatch 'Start-NextQueuedTask\.ps1.+-ConfigPath\s+\$sourceConfigPath') { throw 'Queued task dispatch must reload canonical configuration instead of inheriting the previous task snapshot.' }
Add-Check -Name 'scheduled-host-codex-cli' -Detail 'Workflow, Health Check, and recovery hosts resolve Codex CLI consistently and internal agent runs disable the legacy notify command'

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
if ($scheduledTaskInstaller -notmatch 'Start-AgentContinuationRecoveryHost\.ps1' -or $scheduledTaskInstaller -match '\$continuationArguments.+-RunOnce' -or $scheduledTaskInstaller -notmatch '\$continuationTrigger\s*=\s*New-ScheduledTaskTrigger\s+-Once.+RepetitionInterval' -or $scheduledTaskInstaller -notmatch '-MultipleInstances\s+IgnoreNew' -or $continuationHost -notmatch 'Repair-AgentContinuations\.ps1' -or $continuationHost -notmatch 'while\s*\(\$true\)' -or $continuationHost -notmatch '\[Math\]::Min\(60,\s*\$remainingSeconds\)' -or $continuationHost -notmatch 'Get-EcosystemConfig') {
    throw 'Continuation recovery must keep one resident hidden host and use an ignored-while-running recurring trigger as a watchdog after host termination.'
}
Add-Check -Name 'resident-continuation-watchdog' -Detail 'One resident recovery host reloads config in bounded intervals; recurring triggers are ignored while healthy and relaunch it after termination'
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
$reviewerPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\reviewer.md') -Raw -Encoding UTF8
$reviewVerifierPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\review-verifier.md') -Raw -Encoding UTF8
foreach ($marker in @('/api/tasks','/agents/','/artifacts/','/comments','/diff','/close','/reopen','/api/external-reviews','/external-review-report/','activePullRequests','/api/health-checks/run','/health-recovery/elevated','/workflow/elevated','/workflow/stop','/resume','Start-HealthTargetedResume.ps1','Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Add-TaskComment.ps1','Invoke-EcosystemHealthCheck.ps1','maximumPreviewBytes')) {
    if ($dashboardServer -notmatch [regex]::Escape($marker)) { throw "Dashboard server is missing task-monitor contract marker: $marker" }
}
if ($dashboardServer -notmatch 'Start-ScriptRunspace' -or $dashboardServer -notmatch 'in-process-runspace') { throw 'Elevated workflow must avoid the nested PowerShell process through a tracked in-process runspace.' }
if ($dashboardServer -match 'Start-ScriptProcess' -or $dashboardServer -match 'Start-Process\s+.*powershell' -or $dashboardServer -match 'ExecutionPolicy\s+Bypass') { throw 'Dashboard actions must not create nested PowerShell launchers that host security can block before task state exists.' }
if ($dashboardServer -notmatch '\[string\]::IsNullOrWhiteSpace\(\$ConfigPath\)' -or $dashboardServer -match '\[string\] \$ConfigPath = \(Join-Path') { throw 'Dashboard ConfigPath must be resolved after parameter binding so direct -File startup works in Windows PowerShell 5.1.' }
if ($dashboardServer -notmatch '\$elevatedRequested = \[bool\]\(Get-ObjectPropertyValue -Source \$body -Name ''elevated''\)' -or $dashboardServer -notmatch '\$workflowParameters\.ElevatedApproved = \$true' -or $dashboardClient -notmatch 'payload\.elevated = true' -or $dashboardClient -notmatch 'Start this workflow in host-compatible elevated mode') { throw 'Start Workflow elevated execution must require explicit UI confirmation and use the in-process runspace.' }
if ($dashboardServer -notmatch 'tasks=@\(\$result\.Tasks\)') { throw 'Dashboard API must expose the task collection as lower-camel-case tasks.' }
if ($dashboardClient -notmatch 'selectedTaskId = item.taskId;' -or $dashboardClient -notmatch 'const selectedRevision = \+\+taskStateRevision;' -or $dashboardClient -notmatch 'try \{' -or $dashboardClient -notmatch 'await loadTaskDetail\(item\.taskId, selectedRevision\)' -or $dashboardClient -notmatch 'catch \(error\)' -or $dashboardClient -notmatch 'log\(`Error: \$\{error\.message\}`\)' -or $dashboardClient -notmatch 'finally \{' -or $dashboardClient -notmatch 'void loadTaskList\(\{ silent: true \}\)') { throw 'Task selection must invalidate stale detail responses and load the clicked task directly when background polling is in flight.' }
if ((Get-Content -LiteralPath (Join-Path $root 'scripts\Continue-AgentChain.ps1') -Raw -Encoding UTF8) -notmatch '\$currentAgentId -in @\(''orchestrator'',''health_check''\)') { throw 'Health Check continuation must dispatch the first routed role even when the selected mode disables post-role automatic continuation.' }
if ($dashboardServer -notmatch 'Test-TaskWorkflowActive' -or $dashboardServer -notmatch 'Start-DevelopmentWorkflow\.ps1' -or $dashboardServer -notmatch 'Get-CimInstance Win32_Process' -or $dashboardServer -notmatch 'idle-awaiting-approval' -or $dashboardServer -notmatch 'queued-for-checkpoint' -or $dashboardClient -notmatch 'confirmIdleAgentDispatch' -or $dashboardClient -notmatch 'autoStartIdle: false') { throw 'Idle targeted comments are not wired to approval-gated immediate dispatch and active-workflow batching.' }
foreach ($controlId in @('repositoryOptions','repositorySummary','capacityStatus','taskList','taskDetail','taskLeaseSummary','taskWorkspaceInfo','inputRequiredPanel','openQuestions','taskInterventionPanel','taskComment','taskQuestionTarget','sendTaskComment','resumeTask','stopWorkflow','resumeElevatedWorkflow','executionPolicyNotice','runHealthCheck','artifactViewer','artifactContent','closeArtifactViewer','agentLogPanel','agentLogTitle','agentLogMeta','agentLogEntries','closeAgentLog','agentOutcomePanel','agentOutcomeTitle','agentOutcomeMeta','agentOutcomeSummary','agentOutcomeArtifacts','agentOutcomeArtifactMeta','agentOutcomeContent','closeAgentOutcome','openReviewDiff','reviewDiffPanel','reviewDiffScope','reviewFeedbackTitle','reviewFeedbackSummary','reviewFeedbackList','reviewQuestionThreadsList','reviewFeedbackStatus','requirementTraceabilitySummary','requirementTraceabilityList','reviewCoverageTitle','reviewCoverageSummary','reviewCoverageMatrix','findingLifecycleTitle','findingLifecycleSummary','findingLifecycleList','reviewDiffCommentDock','reviewDiffCommentPanel','reviewDiffCommentKind','externalReviewWorkspace','externalReviewList','externalReviewSummary','refreshExternalReviews','manualClosePanel','manualCloseReason','closeTaskManually','reopenTaskPanel','reopenTaskReason','reopenTask','agentComment','agentActionStatus','sendAgentComment','restartAgentWithComment','approveElevatedRecovery')) {
    if ($dashboardHtml -notmatch ('id=["'']' + [regex]::Escape($controlId) + '["'']')) { throw "Dashboard UI is missing control: $controlId" }
    if ($dashboardClient -notmatch [regex]::Escape("#$controlId")) { throw "Dashboard client does not use control: $controlId" }
}
if ($dashboardHtml -notmatch 'id=["'']requirementTraceabilityTitle["'']') { throw 'Dashboard UI is missing the Requirement Traceability heading.' }
foreach ($marker in @('resetReviewDiffCommentEditor','isSameSelection','renderInlineReviewerComments','renderRequirementTraceability','renderReviewCoverage','renderFindingLifecycle','reviewVerificationFor','findingLifecycleFor','reviewerCodeLocation','row.dataset.newLine','click the selected line again to close','Select a diff line first.')) {
    if ($dashboardClient -notmatch [regex]::Escape($marker)) { throw "Dashboard local review is missing inline comment or traceability behavior: $marker" }
}
if ($dashboardHtml -notmatch 'reviewDiffCommentDock' -or $dashboardCss -notmatch 'height:\s*clamp\(420px,\s*68vh,\s*900px\)' -or $dashboardCss -notmatch 'scrollbar-gutter:\s*stable') { throw 'Dashboard diff viewer must keep the selected-line editor in the diff and provide independent file scrolling.' }
$taskDiffScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-TaskDiff.ps1') -Raw -Encoding UTF8
if ($taskDiffScript -notmatch "ValidateSet\('reviewed-commit','all-task-changes'\)" -or $taskDiffScript -notmatch "reviewedRevision -match '\^git:" -or $taskDiffScript -notmatch 'Get-GitObjectId' -or $taskDiffScript -notmatch "\^\[0-9a-fA-F\]\{40,64\}\$" -or $taskDiffScript -notmatch '\$diffTarget\^' -or $dashboardClient -notmatch "reviewDiffScope = 'reviewed-commit'" -or $dashboardClient -notmatch 'all-task-changes' -or $dashboardServer -notmatch "Diff scope is not supported") { throw 'Reviewer diff must accept only validated object IDs, default to the exact reviewed commit against its first parent, and retain an all-task-changes option.' }
Add-Check -Name 'reviewer-diff-scope' -Detail 'Reviewer diff defaults to reviewed commit versus first parent; dashboard can switch to the complete task-branch diff'
if ($taskDiffScript -notmatch '\(\?:;\|\$\)') { throw 'Reviewer diff must parse extended git revision evidence that also contains its review base.' }
$reviewResultSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\review-result.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$reviewVerificationSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\review-verification.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($reviewResultSchema.required) -notcontains 'requirementTraceability' -or @($reviewResultSchema.required) -notcontains 'reviewCoverage' -or @($reviewResultSchema.required) -notcontains 'findingLifecycle' -or -not $reviewResultSchema.properties.requirementTraceability -or -not $reviewResultSchema.'$defs'.finding.properties.codeLocation) { throw 'Review result schema must require traceability, the complete review coverage matrix, finding lifecycle, and structured inline code locations.' }
if (@($reviewVerificationSchema.required) -notcontains 'reviewArtifactSha256' -or @($reviewVerificationSchema.required) -notcontains 'coverageVerification' -or @($reviewVerificationSchema.required) -notcontains 'findingVerifications' -or @($reviewVerificationSchema.required) -notcontains 'lifecycleVerifications') { throw 'Independent review verification must bind coverage, findings, and lifecycle verdicts to the exact review SHA.' }
if ($reviewerPrompt -notmatch 'Do not read or write `review-verification.json`' -or $reviewVerifierPrompt -notmatch 'Do not read Reviewer private checkpoints' -or $reviewVerifierPrompt -notmatch 'SHA-256') { throw 'Reviewer and Review Verifier context boundaries are not independent or exact-artifact-bound.' }
Add-Check -Name 'independent-review-verification-contract' -Detail 'Reviewer publishes candidates, coverage, and lifecycle; a separate read-only verifier falsifies them against the exact artifact SHA'
$reviewVerificationContract = & (Join-Path $root 'tests\Test-ReviewVerification.ps1') -ConfigPath $ConfigPath -OutputRoot (Join-Path $OutputRoot 'review-verification-contract')
if ([string]$reviewVerificationContract.Status -ne 'passed' -or [int]$reviewVerificationContract.Snapshots -ne 5) { throw 'Independent review verification lifecycle contract failed.' }
Add-Check -Name 'review-verification-lifecycle' -Detail 'Coverage completeness, exact SHA binding, rejected-finding isolation, and new/unchanged/resolved/regressed transitions pass locally'
$requirementsSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\requirements-analysis.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($requirementsSchema.required) -notcontains 'humanReadable' -or -not $requirementsSchema.'$defs'.humanReadable -or -not $requirementsSchema.'$defs'.humanReadable.properties.workflow -or -not $requirementsSchema.'$defs'.humanReadable.properties.implementationPlan) { throw 'Requirements analysis schema must require a human-readable requirements, workflow, and implementation-plan presentation.' }
if ($dashboardClient -notmatch 'renderRequirementsOutcome' -or $dashboardClient -notmatch 'requirementsPresentation' -or $dashboardHtml -notmatch 'agent-outcome-content' -or $dashboardCss -notmatch 'requirements-outcome') { throw 'Dashboard does not interpret the Requirements Analyst presentation while preserving raw outcomes.' }
Add-Check -Name 'human-readable-requirements-outcome' -Detail 'Requirements Analyst schema and dashboard expose requirements, acceptance criteria, workflow, and implementation plan with legacy fallback'
$reviewDecisionsSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\review-decisions.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$techDebtSchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\tech-debt-items.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($reviewDecisionsSchema.properties.decisions.items.properties.decision.enum) -notcontains 'bypassed' -or @($reviewDecisionsSchema.properties.decisions.items.required) -notcontains 'reviewArtifactSha256' -or @($reviewDecisionsSchema.properties.decisions.items.required) -notcontains 'verificationVerdict' -or -not $reviewDecisionsSchema.properties.decisions.items.properties.techDebtItemId -or @($techDebtSchema.'$defs'.item.required) -notcontains 'reviewVerificationArtifact' -or @($techDebtSchema.'$defs'.item.required) -notcontains 'reviewArtifactSha256') { throw 'Review decisions and bypass debt must be bound to an independently verified exact review artifact.' }
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
$reviewQuestionText = @"
[Task diff line comment]
Repository: azure-planningspace-ps-excel-agent
File: src/Synthetic.cs
Old line: n/a
New line: 12
Diff line: + return null;

Why is this null?
"@
$reviewQuestion = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $reviewReplyTaskId -Text $reviewQuestionText -TargetAgentId reviewer -CommentKind review-question -ConfigPath $reviewReplyConfigPath
$reviewQuestionBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -ConfigPath $reviewReplyConfigPath
$reviewQuestionComment = @($reviewQuestionBatch.comments | Where-Object { [string]$_.eventId -eq [string]$reviewQuestion.CommentId }) | Select-Object -First 1
if (-not $reviewQuestionComment -or -not [bool]$reviewQuestionComment.requiresResponse -or [string]$reviewQuestionComment.reviewQuestionId -ne [string]$reviewQuestion.ReviewQuestionId) { throw 'Reviewer line question did not enter the comment batch with a required durable response.' }
$earlyReviewAckRejected = $false
try { & (Join-Path $root 'scripts\Acknowledge-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -EventIds @([string]$reviewQuestion.CommentId) -ConfigPath $reviewReplyConfigPath | Out-Null }
catch { $earlyReviewAckRejected = $_.Exception.Message -match 'before persisting an answer' }
if (-not $earlyReviewAckRejected) { throw 'Reviewer could acknowledge a line question before answering it.' }
$reviewAnswer = & (Join-Path $root 'scripts\Add-ReviewQuestionResponse.ps1') -TaskId $reviewReplyTaskId -ReviewQuestionId ([string]$reviewQuestion.ReviewQuestionId) -Answer 'Verified fact: the null disables the optional branch for this call.' -Evidence @('src/Synthetic.cs:12') -ConfigPath $reviewReplyConfigPath
$reviewQuestionBatchAfterAnswer = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -ConfigPath $reviewReplyConfigPath
$answeredComment = @($reviewQuestionBatchAfterAnswer.comments | Where-Object { [string]$_.eventId -eq [string]$reviewQuestion.CommentId }) | Select-Object -First 1
if (-not $answeredComment -or [bool]$answeredComment.requiresResponse -or [string]$reviewAnswer.SourceCommentId -ne [string]$reviewQuestion.CommentId) { throw 'Persisted Reviewer answer did not close the line-question response gate.' }
& (Join-Path $root 'scripts\Acknowledge-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -EventIds @([string]$reviewQuestion.CommentId) -ConfigPath $reviewReplyConfigPath | Out-Null
$followUpText = $reviewQuestionText -replace 'Why is this null\?', 'Does the same reasoning apply to the alternate caller?'
$reviewFollowUp = & (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $reviewReplyTaskId -Text $followUpText -TargetAgentId reviewer -CommentKind review-question -ParentReviewQuestionId ([string]$reviewQuestion.ReviewQuestionId) -ConfigPath $reviewReplyConfigPath
$reviewFollowUpBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -ConfigPath $reviewReplyConfigPath
$reviewFollowUpComment = @($reviewFollowUpBatch.comments | Where-Object { [string]$_.eventId -eq [string]$reviewFollowUp.CommentId }) | Select-Object -First 1
$reviewFollowUpEvents = Get-Content -LiteralPath (Join-Path $reviewReplyTask.TaskRoot 'task-ledger.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }
$reviewFollowUpQuestionEvent = @($reviewFollowUpEvents | Where-Object eventId -eq $reviewFollowUp.ReviewQuestionId) | Select-Object -First 1
if (-not $reviewFollowUpComment -or -not [bool]$reviewFollowUpComment.requiresResponse -or [string]$reviewFollowUp.ParentReviewQuestionId -ne [string]$reviewQuestion.ReviewQuestionId -or @($reviewFollowUpQuestionEvent.evidence) -notcontains "parent-review-question:$([string]$reviewQuestion.ReviewQuestionId)") { throw 'Reviewer answer follow-up was not durably linked or response-gated.' }
$reviewFollowUpAnswer = & (Join-Path $root 'scripts\Add-ReviewQuestionResponse.ps1') -TaskId $reviewReplyTaskId -ReviewQuestionId ([string]$reviewFollowUp.ReviewQuestionId) -Answer 'Verified fact: the alternate caller uses the same optional branch contract.' -Evidence @('src/Synthetic.cs:18') -ConfigPath $reviewReplyConfigPath
& (Join-Path $root 'scripts\Acknowledge-AgentCommentBatch.ps1') -TaskId $reviewReplyTaskId -AgentId reviewer -EventIds @([string]$reviewFollowUp.CommentId) -ConfigPath $reviewReplyConfigPath | Out-Null
if ($dashboardClient -notmatch 'review-question-opened' -or $dashboardClient -notmatch 'review-question-answered' -or $dashboardClient -notmatch 'createInlineReviewQuestion' -or $dashboardClient -notmatch 'renderReviewQuestionThreads' -or $dashboardClient -notmatch 'sendReviewQuestionFollowUp' -or $dashboardClient -notmatch 'parentReviewQuestionId' -or $reviewerPrompt -notmatch 'Add-ReviewQuestionResponse.ps1') { throw 'Reviewer question threads, visible answers, or follow-up replies are not wired end to end.' }
Add-Check -Name 'reviewer-line-question-answers' -Detail 'Line questions and follow-ups remain response-gated, Reviewer persists cited answers, and dashboard renders a visible replyable thread plus exact-line context'
foreach ($scriptName in @('Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Get-AgentCommentBatch.ps1','Acknowledge-AgentCommentBatch.ps1','Add-ReviewQuestionResponse.ps1','Request-OrchestratorCommentRouting.ps1','Set-WorkflowInputRoute.ps1','Update-AgentContextPack.ps1','Provision-TaskWorkspace.ps1','Resolve-TaskWorkspace.ps1','Release-TaskWorkspaceLease.ps1','Update-TaskWorkspaceLeaseHeartbeat.ps1','Repair-StaleTaskWorkspaceLeases.ps1','Switch-TaskWorkspace.ps1','Start-NextQueuedTask.ps1','Write-AgentActivity.ps1','Add-TaskComment.ps1','Open-AgentQuestion.ps1','Resolve-StaleAgentQuestions.ps1','Resolve-RecoveredControlPlaneStatuses.ps1','Assert-TargetAgentTerminalState.ps1','Set-AgentTaskStatus.ps1','Save-AgentCheckpoint.ps1','Publish-AgentOutcome.ps1','Save-ReviewArtifactSnapshot.ps1','New-DeveloperPublicationEvidence.ps1','Test-AgentOutcomeArtifact.ps1','Start-HealthTargetedResume.ps1','Invoke-OrchestratorContinuation.ps1','Continue-AgentChain.ps1','Repair-AgentContinuations.ps1','Start-AgentContinuationRecoveryHost.ps1','New-WeeklyKnowledgeReport.ps1','Get-TaskDiff.ps1','Set-ReviewDecision.ps1','New-ReviewTechDebtItem.ps1','Request-TaskClosure.ps1','Reopen-AgentTask.ps1','Invoke-ReviewedBranchDelivery.ps1','Refresh-TaskPipelineResult.ps1','Sync-TaskPullRequestStatus.ps1','Sync-ActiveTaskPullRequests.ps1','Classify-PipelineFailure.ps1','Request-PipelineRemediation.ps1','Invoke-PostPushPipeline.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$scriptName") -PathType Leaf)) { throw "Task-monitor script is missing: $scriptName" }
}
if ($dashboardClient -notmatch 'selectedAgentId' -or $dashboardClient -notmatch 'loadAgentLog' -or $dashboardClient -notmatch 'agentLogRefreshSeconds \* 1000') { throw 'Dashboard per-agent live log polling is incomplete.' }
if ($dashboardServer -notmatch 'requiredArtifacts=@\(\$_.requiredArtifacts\)' -or $dashboardServer -notmatch 'artifactSha256' -or $dashboardClient -notmatch 'agentRequiredArtifacts' -or $dashboardClient -notmatch 'openAgentOutcome' -or $dashboardClient -notmatch 'reviewVerificationStale' -or $dashboardClient -notmatch 'reviewArtifactSha256') { throw 'Dashboard per-agent outcome mapping or stale review-verification protection is incomplete.' }
if ($dashboardClient -notmatch 'isReviewerItemBypassedAsDebt' -or $dashboardClient -notmatch 'activeReviewerSummary' -or $dashboardClient -notmatch 'hiddenFindingIds' -or $dashboardClient -notmatch 'sourceFindingId' -or $dashboardClient -notmatch 'review-decisions\.json' -or $dashboardClient -notmatch 'tech-debt-items\.json' -or $reviewerPrompt -notmatch 'Omit the debt-backed item from the new active') { throw 'Bypassed findings with linked open technical debt are still exposed as active Reviewer outcome items.' }
Add-Check -Name 'reviewer-active-outcome-filter' -Detail 'Bypassed findings remain auditable in decisions/debt artifacts but are omitted from subsequent active Reviewer outcomes and dashboard cards'
if ($dashboardServer -notmatch 'Stop-ValidatedWorkflowProcessTree' -or $dashboardServer -notmatch 'Stop-TaskScriptRunspaces') { throw 'Stop workflow must terminate only a validated task process tree or tracked runspace.' }
if ($dashboardServer -notmatch 'Assert-TaskViewIsCurrent' -or $dashboardServer -notmatch 'Assert-TaskControllerIsIdle' -or $dashboardClient -notmatch 'taskViewGuard' -or $dashboardClient -notmatch 'expectedRevision' -or $dashboardClient -notmatch 'workspaceLeaseId') { throw 'Resume, targeted restart, and reopen must reject stale revision/run/lease dashboard views.' }
$activityWriter = Get-Content -LiteralPath (Join-Path $root 'scripts\Write-AgentActivity.ps1') -Raw -Encoding UTF8
$activityReader = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentActivity.ps1') -Raw -Encoding UTF8
$taskProtocol = Get-Content -LiteralPath (Join-Path $root 'prompts\common\task-protocol.md') -Raw -Encoding UTF8
if ($taskProtocol -match 'set only Developer back to pending' -or $taskProtocol -notmatch 'set Developer, Reviewer, Review Verifier, and Pipeline Monitor back to pending') { throw 'Pipeline remediation protocol must invalidate every required downstream role without restarting unrelated agents.' }
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
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $terminalStateTaskId -AgentId pipeline_monitor -AgentStatus running -Stage pipeline_waiting -Message 'Synthetic Pipeline Monitor is running.' -ConfigPath $recoveryStatusConfigPath | Out-Null
$terminalFailure = & (Join-Path $root 'scripts\Write-AgentFailure.ps1') -TaskId $terminalStateTaskId -AgentId pipeline_monitor -Stage pipeline_watcher_terminal_evidence -Summary 'Synthetic watcher did not produce terminal evidence.' -Diagnostic 'pipeline-result.json was absent.' -Evidence @('run:synthetic') -ConfigPath $recoveryStatusConfigPath
$failedTerminalState = & (Join-Path $root 'scripts\Assert-TargetAgentTerminalState.ps1') -TaskId $terminalStateTaskId -AgentId pipeline_monitor -ConfigPath $recoveryStatusConfigPath
$terminalFailureTask = Get-Content -LiteralPath (Join-Path $terminalStateTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (
    -not (Test-Path -LiteralPath ([string]$terminalFailure.FailurePath) -PathType Leaf) -or
    -not [bool]$failedTerminalState.Terminal -or [string]$failedTerminalState.AgentStatus -ne 'failed' -or
    [string]$terminalFailureTask.agentStatuses.pipeline_monitor.status -ne 'failed' -or
    [string]$terminalFailureTask.currentStage -ne 'pipeline_watcher_terminal_evidence'
) { throw 'Write-AgentFailure did not make the failed targeted role terminal for the host lifecycle assertion.' }
$targetWorkflowScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
if ($targetWorkflowScript -notmatch 'Execute that role''s work yourself in this Codex process' -or $targetWorkflowScript -notmatch 'do not merely announce or simulate a handoff' -or $targetWorkflowScript -notmatch 'Assert-TargetAgentTerminalState.ps1' -or $targetWorkflowScript -notmatch 'executedAgentId' -or $targetWorkflowScript -notmatch 'automaticContinuation.enabled' -or $targetWorkflowScript -match '\$TargetAgentId -and \$ContinueChain') { throw 'Host terminal lifecycle or configuration-driven automatic continuation is incomplete.' }
Add-Check -Name 'targeted-role-terminal-lifecycle' -Detail 'Targeted roles execute directly in the host Codex run; structured failures become terminal failed state, while running/pending host exits fail closed'

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
$questionReason = 'The ecosystem cannot infer this task-specific decision safely from repository evidence.'
$questionOptions = @('Provide the requested decision.', 'Revise the task so the decision is no longer required.')
$questionRecommendation = $questionOptions[0]
$questionRecommendationRationale = 'Providing the decision preserves the requested scope and lets the owning agent continue.'
$unstructuredQuestionRejected = $false
try {
    & (Join-Path $root 'scripts\Add-TaskEvent.ps1') -TaskId $staleQuestionTaskId -Actor pipeline_monitor -Type question-opened -Summary 'Bare blocker without guidance.' -ConfigPath $staleQuestionConfigPath | Out-Null
}
catch { $unstructuredQuestionRejected = $_.Exception.Message -match 'structured human-intervention guidance' }
if (-not $unstructuredQuestionRejected) { throw 'A bare question-opened event bypassed the structured human-intervention contract.' }
$staleQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $staleQuestionTaskId -AgentId pipeline_monitor -Question 'Is this prior input still required?' -Reason $questionReason -Options $questionOptions -RecommendedOption $questionRecommendation -RecommendationRationale $questionRecommendationRationale -ConfigPath $staleQuestionConfigPath
$restartCutoff = [DateTime]::Parse([string]$staleQuestion.TimestampUtc).ToUniversalTime().AddMilliseconds(1)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $staleQuestionTaskId -Status interrupted -AgentId pipeline_monitor -AgentStatus completed -Stage targeted_agent_completed -Message 'Targeted restart completed without an input gate.' -ConfigPath $staleQuestionConfigPath | Out-Null
$staleResolution = & (Join-Path $root 'scripts\Resolve-StaleAgentQuestions.ps1') -TaskId $staleQuestionTaskId -AgentId pipeline_monitor -RestartedAtUtc $restartCutoff -ConfigPath $staleQuestionConfigPath
$staleQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $staleQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($staleResolution.SupersededQuestionIds) -notcontains [string]$staleQuestion.QuestionId -or @($staleQuestionView.Tasks[0].openQuestions).Count -ne 0) { throw 'A question made obsolete by a successful targeted restart remained visible on the dashboard.' }
$activeQuestionTaskId = 'active-question-' + [guid]::NewGuid().ToString('N')
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $activeQuestionTaskId -TaskSelector synthetic-active-question -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $staleQuestionConfigPath
$activeQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $activeQuestionTaskId -AgentId reviewer -Question 'This input is still required.' -Reason $questionReason -Options $questionOptions -RecommendedOption $questionRecommendation -RecommendationRationale $questionRecommendationRationale -ConfigPath $staleQuestionConfigPath
$activeCutoff = [DateTime]::Parse([string]$activeQuestion.TimestampUtc).ToUniversalTime().AddMilliseconds(1)
$activeResolution = & (Join-Path $root 'scripts\Resolve-StaleAgentQuestions.ps1') -TaskId $activeQuestionTaskId -AgentId reviewer -RestartedAtUtc $activeCutoff -ConfigPath $staleQuestionConfigPath
$activeQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $activeQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($activeResolution.PreservedQuestionIds) -notcontains [string]$activeQuestion.QuestionId -or @($activeQuestionView.Tasks[0].openQuestions).Count -ne 1) { throw 'An agent still waiting_for_input lost its active question.' }
$activeQuestionEvent = $activeQuestionView.Tasks[0].openQuestions[0]
if (
    -not [bool]$activeQuestionEvent.humanIntervention.required -or
    @($activeQuestionEvent.humanIntervention.options).Count -lt 1 -or
    [string]::IsNullOrWhiteSpace([string]$activeQuestionEvent.humanIntervention.reason) -or
    [string]::IsNullOrWhiteSpace([string]$activeQuestionEvent.humanIntervention.recommendedOption) -or
    [string]::IsNullOrWhiteSpace([string]$activeQuestionEvent.humanIntervention.recommendationRationale) -or
    [string]$activeQuestionEvent.summary -notmatch 'Why human intervention is required:'
) { throw 'A waiting outcome did not expose a reason, options, recommendation, and recommendation rationale.' }
Add-Check -Name 'stale-question-reconciliation' -Detail 'Successful targeted restart supersedes obsolete questions while an active waiting_for_input gate remains visible'

$duplicateQuestionTaskId = 'duplicate-question-' + [guid]::NewGuid().ToString('N')
$duplicateQuestionTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $duplicateQuestionTaskId -TaskSelector synthetic-duplicate-question -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $staleQuestionConfigPath
$olderDuplicateQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $duplicateQuestionTaskId -AgentId requirements_analyst -Question 'Provide the sensitivity mapping.' -Reason $questionReason -Options $questionOptions -RecommendedOption $questionRecommendation -RecommendationRationale $questionRecommendationRationale -ConfigPath $staleQuestionConfigPath
$latestDuplicateQuestion = & (Join-Path $root 'scripts\Open-AgentQuestion.ps1') -TaskId $duplicateQuestionTaskId -AgentId requirements_analyst -Question 'Provide the refined sensitivity mapping.' -Reason $questionReason -Options $questionOptions -RecommendedOption $questionRecommendation -RecommendationRationale $questionRecommendationRationale -ConfigPath $staleQuestionConfigPath
$duplicateQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $duplicateQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($duplicateQuestionView.Tasks[0].openQuestions).Count -ne 1 -or [string]$duplicateQuestionView.Tasks[0].openQuestions[0].eventId -ne [string]$latestDuplicateQuestion.QuestionId) { throw 'Dashboard did not collapse duplicate questions from one agent to its latest active input gate.' }
& (Join-Path $root 'scripts\Add-TaskComment.ps1') -TaskId $duplicateQuestionTaskId -QuestionId ([string]$latestDuplicateQuestion.QuestionId) -Text 'Use the accepted sensitivity mapping.' -ConfigPath $staleQuestionConfigPath | Out-Null
$answeredDuplicateQuestionView = & (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $duplicateQuestionTaskId -ConfigPath $staleQuestionConfigPath
if (@($answeredDuplicateQuestionView.Tasks[0].openQuestions).Count -ne 0) { throw 'An older duplicate question reappeared after the latest question was answered.' }
Add-Check -Name 'duplicate-question-collapse' -Detail 'Dashboard exposes only the latest question per agent and keeps older duplicates hidden after that question is answered'

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
$approvedProcessRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId ([string]$approvedProcessInput.eventId) -TargetAgentIds health_check -ExecutionMode ecosystem-repair -Rationale 'The approved process finding modifies the ecosystem control plane, which Health Check owns.' -Confidence high -ConfigPath $routingConfigPath
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
$ecosystemMaintenanceRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $routingTaskId -SourceEventId $ecosystemMaintenanceComment.CommentId -TargetAgentIds health_check -ExecutionMode ecosystem-repair -Rationale 'Source-controlled ecosystem maintenance belongs to Health Check.' -Confidence high -ConfigPath $routingConfigPath
$healthPriorityDispatch = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $routingTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $routingConfigPath
if ([string]$ecosystemMaintenanceRoute.Status -ne 'routed' -or [string]$healthPriorityDispatch.NextAgentId -ne 'health_check') { throw 'Health Check maintenance input did not preempt unrelated pending delivery work.' }
Add-Check -Name 'ecosystem-maintenance-dispatch' -Detail 'A routed Health Check maintenance request preempts unrelated pending delivery work without changing product scope'

$researchTaskId = 'research-routing-' + [guid]::NewGuid().ToString('N')
$researchTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $researchTaskId -TaskSelector synthetic-research-only -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $routingConfigPath
$researchCreatedEvent = Get-Content -LiteralPath (Join-Path $researchTask.TaskRoot 'task-ledger.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'task-created' | Select-Object -First 1
$researchRoute = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $researchTaskId -SourceEventId ([string]$researchCreatedEvent.eventId) -InputKind task-intake -TargetAgentIds requirements_analyst -ExecutionMode research-only -Rationale 'The user requested evidence-backed research only and explicitly prohibited code changes.' -Confidence high -ConfigPath $routingConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $researchTaskId -AgentId requirements_analyst -AgentStatus completed -Stage research_completed -Message 'Research-only analysis completed.' -ConfigPath $routingConfigPath | Out-Null
$researchContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $researchTaskId -CompletedAgentId requirements_analyst -PrepareOnly -ConfigPath $routingConfigPath
$researchTaskAfter = Get-Content -LiteralPath (Join-Path $researchTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$researchRoute.Routing.executionMode -ne 'research-only' -or [bool]$researchRoute.Routing.codeChangesAllowed -or [bool]$researchRoute.Routing.continueAutomatically -or [string]$researchContinuation.Status -ne 'completed') { throw 'Research-only routing did not persist or stop at its no-code terminal boundary.' }
if (@('developer','reviewer','review_verifier','pipeline_monitor','knowledge_keeper','health_check') | Where-Object { [string]$researchTaskAfter.agentStatuses.$_.status -ne 'skipped' }) { throw 'Research-only routing left an excluded agent eligible to run.' }
Add-Check -Name 'intent-scoped-execution-policy' -Detail 'Orchestrator can persist research-only intent, skip excluded roles, and stop continuation after Requirements Analyst'

$schedulerRoot = Join-Path $OutputRoot ('workspace-scheduler-' + [guid]::NewGuid().ToString('N'))
$schedulerSource = Join-Path $schedulerRoot 'source'
$schedulerRemote = Join-Path $schedulerRoot 'remote.git'
$schedulerConfigPath = Join-Path $schedulerRoot 'agents.json'
New-Item -ItemType Directory -Path $schedulerSource -Force | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerSource -Arguments @('init','-b','main') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerSource -Arguments @('config','user.email','ecosystem-tests@example.invalid') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerSource -Arguments @('config','user.name','Agent Ecosystem Tests') | Out-Null
Write-Utf8NoBom -Path (Join-Path $schedulerSource 'tracked.txt') -Content "baseline$([Environment]::NewLine)"
Invoke-SchedulerTestGit -Workspace $schedulerSource -Arguments @('add','tracked.txt') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerSource -Arguments @('commit','-m','baseline') | Out-Null
Invoke-SchedulerTestGit -Workspace $schedulerRoot -Arguments @('clone','--bare',$schedulerSource,$schedulerRemote) | Out-Null

$schedulerConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$schedulerConfig.runtime.stateRoot = Join-Path $schedulerRoot 'state'
$schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath = Join-Path $schedulerRoot 'state\workspace-coordinator.json'
$schedulerConfig.workflow.workspaceScheduling.workspaceRoot = Join-Path $schedulerRoot 'state\workspaces'
$schedulerConfig.workflow.workspaceScheduling.maxActiveTasks = 2
$schedulerRepository = @($schedulerConfig.repositories | Where-Object id -eq 'azure-planningspace-ps-excel-agent') | Select-Object -First 1
$schedulerRepository.url = $schedulerRemote
$schedulerRepository.localWorkspace = $schedulerSource
Write-Utf8NoBom -Path $schedulerConfigPath -Content (($schedulerConfig | ConvertTo-Json -Depth 40) + [Environment]::NewLine)

$taskAId = 'workspace-a-' + [guid]::NewGuid().ToString('N')
$taskBId = 'workspace-b-' + [guid]::NewGuid().ToString('N')
$taskCId = 'workspace-c-' + [guid]::NewGuid().ToString('N')
$taskDId = 'workspace-d-' + [guid]::NewGuid().ToString('N')
foreach ($taskDefinition in @(@($taskAId,'a'),@($taskBId,'b'),@($taskCId,'c'),@($taskDId,'d'))) {
    $null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskDefinition[0] -TaskSelector ('synthetic-workspace-' + $taskDefinition[1]) -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
}
$leaseA = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskAId -RunId ('a' * 32) -ConfigPath $schedulerConfigPath
$leaseB = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskBId -RunId ('b' * 32) -ConfigPath $schedulerConfigPath
$workspaceA = [string]$leaseA.Workspaces[0].Path
$workspaceB = [string]$leaseB.Workspaces[0].Path
if ([string]$leaseA.Status -ne 'active' -or [string]$leaseB.Status -ne 'active' -or $workspaceA -eq $workspaceB -or -not (Test-Path -LiteralPath (Join-Path $workspaceA '.git') -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $workspaceB '.git') -PathType Container)) { throw 'Two tasks targeting one repository did not receive distinct full Git clones.' }
Write-Utf8NoBom -Path (Join-Path $workspaceA 'task-a-uncommitted.txt') -Content "task-a-only$([Environment]::NewLine)"
if (Test-Path -LiteralPath (Join-Path $workspaceB 'task-a-uncommitted.txt')) { throw 'Task A working-tree changes leaked into task B clone.' }
$resolvedA = & (Join-Path $root 'scripts\Resolve-TaskWorkspace.ps1') -TaskId $taskAId -RepositoryId azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
if ([string]$resolvedA.Path -ne $workspaceA -or [string]$resolvedA.LeaseId -ne [string]$leaseA.LeaseId) { throw 'Task workspace resolver did not return the manifest-owned clone.' }
$heartbeatA = & (Join-Path $root 'scripts\Update-TaskWorkspaceLeaseHeartbeat.ps1') -TaskId $taskAId -RunId ('a' * 32) -LeaseId ([string]$leaseA.LeaseId) -ConfigPath $schedulerConfigPath
$coordinatorAfterHeartbeat = Get-Content -LiteralPath $schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$heartbeatLeaseA = @($coordinatorAfterHeartbeat.leases | Where-Object { [string]$_.taskId -eq $taskAId -and [string]$_.leaseId -eq [string]$leaseA.LeaseId }) | Select-Object -First 1
$wrongHeartbeatRejected = $false
try { $null = & (Join-Path $root 'scripts\Update-TaskWorkspaceLeaseHeartbeat.ps1') -TaskId $taskAId -RunId ('a' * 32) -LeaseId ('z' * 32) -ConfigPath $schedulerConfigPath }
catch { $wrongHeartbeatRejected = $_.Exception.Message -match 'no longer owned' }
if ([string]$heartbeatA.Status -ne 'updated' -or -not $heartbeatLeaseA -or -not $heartbeatLeaseA.heartbeatAtUtc -or -not $wrongHeartbeatRejected) { throw 'Workspace heartbeat did not enforce exact task/run/lease ownership.' }
$duplicateControllerRejected = $false
try { $null = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskAId -RunId ('x' * 32) -ConfigPath $schedulerConfigPath }
catch { $duplicateControllerRejected = $_.Exception.Message -match 'already has an active controller' }
if (-not $duplicateControllerRejected) { throw 'A second controller was allowed to enter the same task.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status completed -Stage synthetic-active-reopen-check -ConfigPath $schedulerConfigPath | Out-Null
$activeReopenRejected = $false
try { $null = & (Join-Path $root 'scripts\Reopen-AgentTask.ps1') -TaskId $taskAId -Reason 'Synthetic active lease reopen check.' -ExpectedRevision 1 -ExpectedRunId ('a' * 32) -ExpectedLeaseId ([string]$leaseA.LeaseId) -ConfigPath $schedulerConfigPath }
catch { $activeReopenRejected = $_.Exception.Message -match 'active workspace lease' }
$taskAAfterRejectedReopen = Get-Content -LiteralPath (Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskAId\task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $activeReopenRejected -or [int]$taskAAfterRejectedReopen.revision -ne 1) { throw 'A completed task was reopened while its previous controller lease was still active.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status running -Stage synthetic-resumed-active-check -ConfigPath $schedulerConfigPath | Out-Null

$queuedC = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskCId -RunId ('c' * 32) -ConfigPath $schedulerConfigPath
$queuedD = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskDId -RunId ('d' * 32) -ConfigPath $schedulerConfigPath
if ([string]$queuedC.Status -ne 'queued' -or [int]$queuedC.QueuePosition -ne 1 -or [string]$queuedD.Status -ne 'queued' -or [int]$queuedD.QueuePosition -ne 2) { throw 'Capacity queue did not preserve FIFO positions.' }
& (Join-Path $root 'scripts\Release-TaskWorkspaceLease.ps1') -TaskId $taskBId -LeaseId ([string]$leaseB.LeaseId) -Reason synthetic-complete -ConfigPath $schedulerConfigPath | Out-Null
$stillQueuedD = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskDId -RunId ('d' * 32) -ConfigPath $schedulerConfigPath
if ([string]$stillQueuedD.Status -ne 'queued' -or [int]$stillQueuedD.QueuePosition -ne 2) { throw 'A newer queued task bypassed the older FIFO task when one slot opened.' }
$leaseC = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskCId -RunId ('c' * 32) -ConfigPath $schedulerConfigPath
if ([string]$leaseC.Status -ne 'active') { throw 'The oldest queued task was not admitted into the released slot.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskCId -Status failed -Stage synthetic-failure -Message 'Task C failed independently.' -ConfigPath $schedulerConfigPath | Out-Null
$taskDAfterCFailure = Get-Content -LiteralPath (Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskDId\task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$taskDAfterCFailure.status -ne 'queued') { throw 'Task C failure changed task D queue state.' }
$leaseD = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskDId -RunId ('d' * 32) -ConfigPath $schedulerConfigPath
$coordinatorAfterFailureRecovery = Get-Content -LiteralPath $schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestCAfterFailureRecovery = Get-Content -LiteralPath ([string]$leaseC.Workspaces[0].ManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$leaseD.Status -ne 'active' -or @($coordinatorAfterFailureRecovery.leases | Where-Object { [string]$_.taskId -eq $taskCId }).Count -ne 0 -or [string]$manifestCAfterFailureRecovery.lifecycle -ne 'released' -or [string]$manifestCAfterFailureRecovery.releaseReason -notmatch 'task-terminal:failed') { throw 'A failed task lease blocked the next FIFO task or lost its preserved workspace state.' }

& (Join-Path $root 'scripts\Release-TaskWorkspaceLease.ps1') -TaskId $taskAId -LeaseId ([string]$leaseA.LeaseId) -Reason synthetic-yield -ConfigPath $schedulerConfigPath | Out-Null
& (Join-Path $root 'scripts\Release-TaskWorkspaceLease.ps1') -TaskId $taskDId -LeaseId ([string]$leaseD.LeaseId) -Reason synthetic-complete -ConfigPath $schedulerConfigPath | Out-Null

$taskFId = 'workspace-f-' + [guid]::NewGuid().ToString('N')
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskFId -TaskSelector 'synthetic-controller-crash' -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerConfigPath
$leaseF = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskFId -RunId ('f' * 32) -ConfigPath $schedulerConfigPath
$coordinatorForCrash = Get-Content -LiteralPath $schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$crashedLease = @($coordinatorForCrash.leases | Where-Object { [string]$_.taskId -eq $taskFId }) | Select-Object -First 1
$expiredHeartbeat = [DateTime]::UtcNow.AddSeconds(-([int]$schedulerConfig.workflow.workspaceScheduling.staleLeaseGraceSeconds + 5)).ToString('o')
$crashedLease.controllerProcessId = $PID
$crashedLease.controllerStartedAtUtc = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
$crashedLease.heartbeatAtUtc = $expiredHeartbeat
Write-Utf8NoBom -Path $schedulerConfig.workflow.workspaceScheduling.coordinatorStatePath -Content (($coordinatorForCrash | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$recoveredCrash = @(& (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -ConfigPath $schedulerConfigPath)
$taskFAfterRecovery = Get-Content -LiteralPath (Join-Path $schedulerConfig.runtime.stateRoot "tasks\$taskFId\task.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$manifestFAfterRecovery = Get-Content -LiteralPath ([string]$leaseF.Workspaces[0].ManifestPath) -Raw -Encoding UTF8 | ConvertFrom-Json
if ($recoveredCrash.Count -ne 1 -or [string]$recoveredCrash[0].reason -ne 'heartbeat-expired' -or [string]$taskFAfterRecovery.status -ne 'interrupted' -or [string]$manifestFAfterRecovery.lifecycle -ne 'released' -or -not (Test-Path -LiteralPath (Join-Path ([string]$leaseF.Workspaces[0].Path) '.git') -PathType Container)) { throw 'An expired in-process runspace heartbeat was not recovered while preserving its isolated clone.' }

$taskEId = 'workspace-e-' + [guid]::NewGuid().ToString('N')
$schedulerFailureConfigPath = Join-Path $schedulerRoot 'agents-missing-base.json'
$schedulerFailureConfig = Get-Content -LiteralPath $schedulerConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$schedulerFailureConfig.runtime.defaultBaseBranch = 'definitely-missing-base'
Write-Utf8NoBom -Path $schedulerFailureConfigPath -Content (($schedulerFailureConfig | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskEId -TaskSelector 'synthetic-workspace-provisioning-failure' -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $schedulerFailureConfigPath
$failedRunId = 'e' * 32
$failedLayout = Get-TaskWorkspaceLayout -WorkspaceRoot ([string]$schedulerFailureConfig.workflow.workspaceScheduling.workspaceRoot) -TaskId $taskEId -RepositoryId azure-planningspace-ps-excel-agent -RunId $failedRunId
$failedProvisioningRejected = $false
try { $null = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskEId -RunId $failedRunId -ConfigPath $schedulerFailureConfigPath }
catch { $failedProvisioningRejected = $_.Exception.Message -match 'rev-parse' }
$coordinatorAfterFailedProvisioning = Get-Content -LiteralPath $schedulerFailureConfig.workflow.workspaceScheduling.coordinatorStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$failedLeaseCount = @($coordinatorAfterFailedProvisioning.leases | Where-Object { [string]$_.taskId -eq $taskEId }).Count
if (-not $failedProvisioningRejected -or (Test-Path -LiteralPath ([string]$failedLayout.ClonePath)) -or $failedLeaseCount -ne 0) { throw 'Failed workspace provisioning left a partial clone or capacity lease behind.' }

& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status completed -Stage synthetic-stale-reopen-check -ConfigPath $schedulerConfigPath | Out-Null
$staleReopenRejected = $false
try { $null = & (Join-Path $root 'scripts\Reopen-AgentTask.ps1') -TaskId $taskAId -Reason 'Synthetic stale revision reopen check.' -ExpectedRevision 2 -ExpectedRunId ('a' * 32) -ExpectedLeaseId ([string]$leaseA.LeaseId) -ConfigPath $schedulerConfigPath }
catch { $staleReopenRejected = $_.Exception.Message -match 'revision changed' }
if (-not $staleReopenRejected) { throw 'A stale dashboard revision was allowed to reopen the task.' }
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskAId -Status running -Stage synthetic-resume-check -ConfigPath $schedulerConfigPath | Out-Null
$leaseAResumed = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $taskAId -RunId ('r' * 32) -ConfigPath $schedulerConfigPath
if ([string]$leaseAResumed.Status -ne 'active' -or [string]$leaseAResumed.LeaseId -eq [string]$leaseA.LeaseId -or [string]$leaseAResumed.Workspaces[0].Path -ne $workspaceA -or -not (Test-Path -LiteralPath (Join-Path $workspaceA 'task-a-uncommitted.txt'))) { throw 'Task resume did not reacquire the same preserved clone with a new lease.' }
Add-Check -Name 'parallel-clone-workspace-scheduler' -Detail 'Two tasks can run in distinct full clones of one repository; FIFO capacity, one controller per task, task-local failure, resolver/heartbeat ownership, clone reuse, failed/task-crash lease recovery, and failed-provisioning rollback are enforced'

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
if ([string]$pipelineAgent.reasoningEffort -ne 'low' -or [string]$pipelineAgent.model -ne 'gpt-5.6-luna') { throw 'Pipeline Monitor must use the routine low-cost model tier for deterministic monitoring.' }
$modelRouter = Get-Content -LiteralPath (Join-Path $root 'scripts\Resolve-AgentModelRoute.ps1') -Raw -Encoding UTF8
if (-not [bool]$config.modelRouting.enabled -or [string]$config.modelRouting.artifactName -ne 'model-routing.json' -or @($config.modelRouting.tiers).Count -ne 4 -or @($config.modelRouting.rolePolicies).Count -ne @($config.agents).Count -or $workflowRunner -notmatch "--model" -or $workflowRunner -notmatch 'model_reasoning_effort=' -or $workflowRunner -notmatch 'Resolve-AgentModelRoute.ps1' -or $modelRouter -notmatch 'inputFingerprint' -or $modelRouter -notmatch 'role-policy-clamp' -or $getTasksScript -notmatch 'modelRouteDecisions' -or $dashboardClient -notmatch 'modelRoute\.complexity') { throw 'Deterministic per-agent model routing is incomplete.' }
$modelRouteRoot = Join-Path $OutputRoot 'model-routing'
$modelRouteConfigPath = Join-Path $modelRouteRoot 'agents.json'
$modelRouteConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$modelRouteConfig.runtime.stateRoot = Join-Path $modelRouteRoot 'state'
New-Item -ItemType Directory -Path $modelRouteRoot -Force | Out-Null
Write-Utf8NoBom -Path $modelRouteConfigPath -Content (($modelRouteConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$modelRouteTaskId = 'model-route-' + [guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $modelRouteTaskId -TaskSelector 'Routine status classification.' -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $modelRouteConfigPath | Out-Null
$routineRoute = & (Join-Path $root 'scripts\Resolve-AgentModelRoute.ps1') -TaskId $modelRouteTaskId -AgentId pipeline_monitor -TaskSelector 'Classify the known test result.' -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $modelRouteConfigPath
$reusedRoute = & (Join-Path $root 'scripts\Resolve-AgentModelRoute.ps1') -TaskId $modelRouteTaskId -AgentId pipeline_monitor -TaskSelector 'Classify the known test result.' -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $modelRouteConfigPath
$criticalRoute = & (Join-Path $root 'scripts\Resolve-AgentModelRoute.ps1') -TaskId $modelRouteTaskId -AgentId developer -TaskSelector 'Correct the security vulnerability in authentication and Key Vault code signing across repositories.' -RepositoryIds @('azure-planningspace-ps-excel-agent','azure-planningspace-ps-bicep') -ConfigPath $modelRouteConfigPath
$routingArtifact = Get-Content -LiteralPath (Join-Path $modelRouteConfig.runtime.stateRoot "tasks\$modelRouteTaskId\model-routing.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$routineRoute.complexity -ne 'routine' -or [string]$routineRoute.model -ne 'gpt-5.6-luna' -or -not [bool]$reusedRoute.reused -or [string]$criticalRoute.complexity -ne 'critical' -or [string]$criticalRoute.model -ne 'gpt-5.6-sol' -or @($routingArtifact.decisions).Count -ne 2) { throw 'Model router did not preserve routine cost, reuse an unchanged fingerprint, or escalate critical multi-repository security work.' }
Add-Check -Name 'deterministic-model-routing' -Detail 'Every Codex role run receives an auditable JSON-selected model/effort with deterministic reuse, risk escalation, and role floors/caps'
$pipelinePrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\pipeline-monitor.md') -Raw -Encoding UTF8
if ($pipelinePrompt -notmatch 'Refresh-TaskPipelineResult.ps1' -or $pipelinePrompt -notmatch 'Pull-request creation is never a prerequisite' -or $pipelinePrompt -notmatch 'older in-progress retry must not hide a newer terminal run') { throw 'Pipeline Monitor targeted restart must refresh the newest exact-SHA logs before PR synchronization.' }
$pipelineDeliverySkill = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\monitor-delivery-pipelines\SKILL.md') -Raw -Encoding UTF8
$azurePipelineMonitorSkill = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\SKILL.md') -Raw -Encoding UTF8
foreach ($watcherInstruction in @($pipelinePrompt, $pipelineDeliverySkill, $azurePipelineMonitorSkill)) {
    if ($watcherInstruction -notmatch 'running cell or session' -or $watcherInstruction -notmatch 'retain (its |the )?handle' -or $watcherInstruction -notmatch 'wait/resume mechanism' -or $watcherInstruction -notmatch 'Do not start another (refresh or watcher|watcher or refresh) while (the |that )?handle is live' -or $watcherInstruction -notmatch 'inProgress.*not a failure' -or $watcherInstruction -notmatch 'terminal watcher completion or a real nonzero exit') { throw 'Pipeline watcher instructions must retain yielded execution handles, avoid duplicate watchers, and treat in-progress yields as non-failures.' }
}
Add-Check -Name 'pipeline-watcher-yield-resume' -Detail 'Pipeline Monitor retains a yielded watcher handle, resumes the same command, avoids duplicate refresh/watchers, and treats inProgress as non-terminal'
$pipelineRefreshScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Refresh-TaskPipelineResult.ps1') -Raw -Encoding UTF8
if ($pipelineRefreshScript -notmatch '\$commitExitCode\s*=\s*\$LASTEXITCODE' -or $pipelineRefreshScript -notmatch '\$remoteCommitExitCode\s*=\s*\$LASTEXITCODE' -or $pipelineRefreshScript -match 'if\s*\(\$LASTEXITCODE\s+-ne\s+0\s+-or\s+\$Commit') { throw 'Pipeline refresh must not read an unset LASTEXITCODE when Branch or Commit is supplied explicitly.' }
Add-Check -Name 'pipeline-refresh-explicit-commit' -Detail 'Explicit branch and commit refresh validates values without reading a stale or unset LASTEXITCODE'
$postPushPipelineScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-PostPushPipeline.ps1') -Raw -Encoding UTF8
if ($postPushPipelineScript -notmatch 'if\s*\(-not\s+\$Branch\)\s*\{[^}]*\$LASTEXITCODE' -or $postPushPipelineScript -notmatch 'if\s*\(-not\s+\$Commit\)\s*\{[^}]*\$LASTEXITCODE' -or $postPushPipelineScript -match 'if\s*\(\$LASTEXITCODE\s+-ne\s+0\s+-or\s+-not\s+\$Branch') { throw 'Post-push monitoring must not read an unset LASTEXITCODE when Branch and Commit are supplied explicitly.' }
Add-Check -Name 'post-push-explicit-commit' -Detail 'Explicit post-push branch and commit bypass ambient LASTEXITCODE and remain exact-SHA validated'
$pipelineWatcherScript = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Raw -Encoding UTF8
if ($pipelineWatcherScript -notmatch 'azdo-.*NewGuid' -or $pipelineWatcherScript -notmatch 'finally\s*\{\s*if\s*\(Test-Path -LiteralPath \$logFile') { throw 'Pipeline failed-log retrieval must use a unique non-existing temp path and guarantee cleanup.' }
Add-Check -Name 'pipeline-log-temp-files' -Detail 'Every Azure failed-log download uses a unique path and removes it after bounded extraction'
if (-not [bool]$config.pipeline.postPush.enabled -or [int]$config.pipeline.postPush.maxRemediationCycles -ne 3 -or [int]$config.pipeline.postPush.activityHeartbeatSeconds -ne 60) { throw 'Post-push monitoring must be enabled with a 60-second activity heartbeat and three-cycle remediation ceiling.' }
if (-not [bool]$config.workflow.automaticContinuation.enabled -or [int]$config.workflow.automaticContinuation.maxChainSteps -ne 16 -or [int]$config.workflow.automaticContinuation.maxTransitionRepeats -ne 3 -or -not [bool]$config.workflow.automaticContinuation.useElevatedExecution) { throw 'Automatic targeted continuation configuration is incomplete.' }
if (-not [bool]$config.workflow.orchestration.outcomeDrivenTransitions -or [string]$config.workflow.orchestration.transitionEntryPoint -ne '${REPO_ROOT}/scripts/Invoke-OrchestratorContinuation.ps1') { throw 'Successful role outcomes do not return through the canonical Orchestrator control plane.' }
if (-not [bool]$config.pipeline.delivery.autoPushAfterCleanReview -or [bool]$config.pipeline.delivery.allowForce -or [bool]$config.pipeline.delivery.allowTags -or [int]$config.pipeline.pullRequests.pollIntervalMinutes -ne 120) { throw 'Guarded delivery or two-hour PR lifecycle polling configuration is invalid.' }
if ([bool]$config.review.excludeSelfAuthored) { throw 'Review Monitor must include PRs authored by the configured reviewer as well as assigned PRs.' }
$pipelineOwnership = $config.pipeline.ownership
$pipelineOwnershipContract = @(
    [string]$pipelineOwnership.monitorAgentId,
    [string]$pipelineOwnership.productRemediationAgentId,
    [string]$pipelineOwnership.remediationReviewAgentId,
    [string]$pipelineOwnership.reviewVerificationAgentId,
    [string]$pipelineOwnership.exceptionRoutingAgentId,
    [string]$pipelineOwnership.ecosystemRecoveryAgentId,
    [string]$pipelineOwnership.completionAgentId
) -join ','
if ($pipelineOwnershipContract -ne 'pipeline_monitor,developer,reviewer,review_verifier,orchestrator,health_check,knowledge_keeper') { throw 'Pipeline ownership must explicitly preserve monitoring, remediation, independent review verification, exception, ecosystem recovery, and completion responsibilities.' }
$excelPipeline = @($config.pipeline.repositories | Where-Object repositoryId -eq 'azure-planningspace-ps-excel-agent') | Select-Object -First 1
if ((@($excelPipeline.autoQueueDefinitionIds) -join ',') -ne '814,892' -or (@($excelPipeline.skipOnMissingYamlDefinitionIds) -join ',') -ne '892' -or @($config.pipeline.repositories.autoQueueDefinitionIds) -contains 891) { throw 'Approved build definitions must be ordered 814 then 892; only 892 may be skipped for a missing YAML; deployment 891 is forbidden.' }
$delfiPipeline = @($config.pipeline.repositories | Where-Object repositoryId -eq 'azure-palantirplugins-ps-app-delfi') | Select-Object -First 1
if ((@($delfiPipeline.definitionIds) -join ',') -ne '17' -or @($delfiPipeline.autoQueueDefinitionIds).Count -ne 0) { throw 'ps-app-delfi definition 17 must be observed passively and must never be auto-queued.' }
Add-Check -Name 'configuration-semantics' -Detail "mode=$($config.operation.mode); repositories=$(@($config.repositories).Count); agents=$(@($config.agents).Count); pipelineOwners=$pipelineOwnershipContract"

$pipelineTestRoot = Join-Path $OutputRoot 'pipeline-monitor'
New-Item -ItemType Directory -Path $pipelineTestRoot -Force | Out-Null
$pipelineRecoveryRoot = Join-Path $pipelineTestRoot ('recovery-' + [guid]::NewGuid().ToString('N'))
$pipelineRecovery = & (Join-Path $root 'tests\Test-PipelineWatcherRecovery.ps1') -ConfigPath $ConfigPath -OutputRoot $pipelineRecoveryRoot -CodexHome $CodexHome
if ([string]$pipelineRecovery.collectionShapes -ne 'passed' -or [string]$pipelineRecovery.pullRequestStringCorrelation -ne 'passed' -or [string]$pipelineRecovery.pullRequestObjectCorrelation -ne 'passed' -or [int]$pipelineRecovery.passiveDefinitionId -ne 17 -or [int]$pipelineRecovery.queuedDefinitionCount -ne 0 -or [string]$pipelineRecovery.productionWrapper -ne 'passed' -or [string]$pipelineRecovery.postPushRemediationTerminal -ne 'passed' -or [string]$pipelineRecovery.originCommitGate -ne 'passed') { throw 'Bounded pipeline watcher recovery regression did not validate all required contracts.' }
Add-Check -Name 'pipeline-watcher-recovery' -Detail 'Zero, singleton, and multiple Azure shapes; exact direct/PR source commit correlation; passive definition 17; no queue; production wrapper, terminal remediation handoff, and origin gate'
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
$optionalYamlStatePath = Join-Path $pipelineTestRoot 'optional-missing-yaml-state.txt'
$optionalYamlResultPath = Join-Path $pipelineTestRoot 'optional-missing-yaml-result.json'
Remove-Item -LiteralPath $optionalYamlStatePath -Force -ErrorAction SilentlyContinue
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'ordered-optional-missing-yaml'
$env:ECOSYSTEM_MOCK_PIPELINE_STATE = $optionalYamlStatePath
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $optionalYamlResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -AutoQueueDefinitionIds 814,892 -SkipOnMissingYamlDefinitionIds 892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $optionalYamlResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -PassThru
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
if ([string]$optionalYamlResult.overallResult -ne 'succeeded' -or (@($optionalYamlResult.queuedDefinitionIds) -join ',') -ne '814' -or (@($optionalYamlResult.runs.definitionId) -join ',') -ne '814' -or [string]$optionalYamlResult.summary -notmatch 'Skipped optional missing-YAML definition\(s\): 892' -or (@(Get-Content -LiteralPath $optionalYamlStatePath) -join ',') -ne 'queued:814,succeeded:814,missing-yaml:892') { throw 'The optional missing-YAML fallback did not preserve the required 814 success or report the skipped 892 definition.' }
Add-Check -Name 'optional-missing-yaml-pipeline-fallback' -Detail 'Definition 892 is skipped only for Azure missing-YAML validation; required 814 still succeeds'
$queueDiagnosticStatePath = Join-Path $pipelineTestRoot 'queue-diagnostic-state.txt'
$queueDiagnosticResultPath = Join-Path $pipelineTestRoot 'queue-diagnostic-result.json'
$queueDiagnosticStages = [Collections.Generic.List[string]]::new()
$queueDiagnosticProgress = { param($Stage, $Summary, $Details) $queueDiagnosticStages.Add([string]$Stage) }.GetNewClosure()
Remove-Item -LiteralPath $queueDiagnosticStatePath -Force -ErrorAction SilentlyContinue
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'queue-validation-missing-environment'
$env:ECOSYSTEM_MOCK_PIPELINE_STATE = $queueDiagnosticStatePath
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $queueDiagnosticResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -AutoQueueDefinitionIds 892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $queueDiagnosticResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -ProgressCallback $queueDiagnosticProgress -PassThru
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
$queueAttempts = @(Get-Content -LiteralPath $queueDiagnosticStatePath)
$missingEnvironmentCheck = @($queueDiagnosticResult.queueFailure.resourceChecks | Where-Object { [string]$_.kind -eq 'environment' -and [string]$_.name -eq 'promote-to-cloudops' -and [string]$_.status -eq 'not-visible' })
if ([string]$queueDiagnosticResult.overallResult -ne 'non-success' -or [string]$queueDiagnosticResult.failureClassification.category -ne 'infrastructure' -or -not [bool]$queueDiagnosticResult.queueFailure.preview.succeeded -or $missingEnvironmentCheck.Count -ne 1) { throw 'Queue rejection was not converted into actionable missing-Environment diagnostics.' }
$queueGuidance = $queueDiagnosticResult.queueFailure.humanIntervention
$reuseEnvironmentOption = @($queueGuidance.options | Where-Object { [string]$_.id -eq 'reuse-visible-environment' -and [string]$_.action -match 'cloudops-promote' })
if (
    -not [bool]$queueGuidance.required -or
    [string]::IsNullOrWhiteSpace([string]$queueGuidance.reason) -or
    $reuseEnvironmentOption.Count -ne 1 -or
    [string]$queueGuidance.recommendedOptionId -ne 'reuse-visible-environment' -or
    [string]::IsNullOrWhiteSpace([string]$queueGuidance.recommendationRationale)
) { throw 'Queue diagnostics did not recommend the visible matching Environment with actionable rationale.' }
if ($queueAttempts.Count -ne 1 -or $queueAttempts[0] -ne 'queue-attempt:892') { throw 'Queue diagnostics repeated or replaced the single authorized queue attempt.' }
if ([string]$queueDiagnosticResult.queueFailure.queueError -match 'must-not-leak' -or [string]$queueDiagnosticResult.queueFailure.queueError -notmatch '<redacted>') { throw 'Queue diagnostics did not redact credential-shaped Azure CLI output.' }
if (@($queueDiagnosticStages) -notcontains 'pipeline_queueing' -or @($queueDiagnosticStages) -notcontains 'pipeline_failure_analysis' -or @($queueDiagnosticStages) -notcontains 'pipeline_terminal') { throw 'Queue diagnostics did not publish queueing, failure-analysis, and terminal progress stages.' }
if (-not (Test-Path -LiteralPath $queueDiagnosticResultPath -PathType Leaf) -or $null -eq (Get-Content -LiteralPath $queueDiagnosticResultPath -Raw | ConvertFrom-Json).queueFailure) { throw 'Queue diagnostics were not persisted in pipeline-result.json.' }
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'queue-validation-preview-environment'
$env:ECOSYSTEM_MOCK_PIPELINE_STATE = $queueDiagnosticStatePath
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $previewEnvironmentDiagnostic = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\diagnose_queue_validation.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -DefinitionId 892 -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -QueueError 'Could not queue the build because there were validation errors or warnings.' -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1')
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
$previewEnvironmentCheck = @($previewEnvironmentDiagnostic.resourceChecks | Where-Object { [string]$_.kind -eq 'environment' -and [string]$_.name -eq 'promote-to-cloudops' -and [string]$_.status -eq 'not-visible' })
if ([bool]$previewEnvironmentDiagnostic.preview.succeeded -or $previewEnvironmentCheck.Count -ne 1 -or [string]$previewEnvironmentDiagnostic.category -ne 'infrastructure') { throw 'Exact Azure dry-run Environment validation text was not converted into a structured infrastructure resource check.' }
if ([string]$previewEnvironmentDiagnostic.humanIntervention.recommendedOptionId -ne 'reuse-visible-environment' -or @($previewEnvironmentDiagnostic.humanIntervention.options | Where-Object { [string]$_.action -match 'cloudops-promote' }).Count -ne 1) { throw 'Preview failure diagnostics did not use the read-only Environment inventory to recommend the matching shared Environment.' }
Add-Check -Name 'pipeline-queue-validation-diagnostics' -Detail 'One queue attempt; exact-SHA dry-run preview; read-only resource checks; sanitized result; actionable options with a reasoned recommendation'
$preJobResultPath = Join-Path $pipelineTestRoot 'pre-job-validation-result.json'
$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO = 'pre-job-validation'
$env:ECOSYSTEM_MOCK_COMMIT = '0123456789abcdef0123456789abcdef01234567'
try {
    $preJobResult = & (Join-Path $root 'plugins\development-agent-ecosystem\skills\azure-pipeline-monitor\scripts\watch_pipeline_runs.ps1') -Organization 'https://dev.azure.com/example' -Project 'Example' -Branch 'feature/synthetic' -Commit $env:ECOSYSTEM_MOCK_COMMIT -DefinitionIds 892 -QueuedAfter ([DateTime]::UtcNow.AddMinutes(-1)) -PollSeconds 0 -DiscoveryTimeoutMinutes 1 -RunTimeoutMinutes 1 -AzCli (Join-Path $root 'tests\fixtures\Mock-AzurePipelineCli.ps1') -TaskId $pipelineTestTaskId -RepositoryId 'azure-planningspace-ps-excel-agent' -ResultPath $preJobResultPath -ClassifierScript (Join-Path $root 'scripts\Classify-PipelineFailure.ps1') -PassThru
}
finally {
    Remove-Item Env:\ECOSYSTEM_MOCK_PIPELINE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:\ECOSYSTEM_MOCK_COMMIT -ErrorAction SilentlyContinue
}
$preJobTask = @($preJobResult.runs[0].failedTasks | Where-Object { [string]$_.name -eq 'Azure pipeline validation' -and [string]$_.logExcerpt -match 'quorumcr-fdplan-push' })
if (
    [string]$preJobResult.overallResult -ne 'non-success' -or
    [string]$preJobResult.failureClassification.category -ne 'infrastructure' -or
    $preJobTask.Count -ne 1 -or
    [string]$preJobResult.humanIntervention.recommendedOptionId -ne 'authorize-service-connection' -or
    @($preJobResult.humanIntervention.options | Where-Object { [string]$_.id -eq 'authorize-service-connection' -and [string]$_.action -match 'definition 892' }).Count -ne 1
) { throw 'Pre-job Azure validation was not converted into a structured infrastructure result with a reasoned service-connection recommendation.' }
Add-Check -Name 'pipeline-pre-job-validation-diagnostics' -Detail 'Run validationResults are classified without timeline/logs and recommend scoped service-connection authorization'
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
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $pipelineTestTaskId -AgentId reviewer -AgentStatus completed -ConfigPath $pipelineTestConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $pipelineTestTaskId -AgentId review_verifier -AgentStatus completed -ConfigPath $pipelineTestConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $pipelineTestTaskId -AgentId pipeline_monitor -AgentStatus completed -ConfigPath $pipelineTestConfigPath | Out-Null
$firstRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$duplicateRemediation = & (Join-Path $root 'scripts\Request-PipelineRemediation.ps1') -TaskId $pipelineTestTaskId -PipelineResultPath $pipelineResultPath -ConfigPath $pipelineTestConfigPath
$pipelineTaskState = Get-Content -LiteralPath $pipelineTestTask.TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [bool]$firstRemediation.Requested -or [bool]$duplicateRemediation.Requested -or [string]$pipelineTaskState.status -ne 'interrupted' -or [string]$pipelineTaskState.agentStatuses.developer.status -ne 'pending' -or [string]$pipelineTaskState.agentStatuses.reviewer.status -ne 'pending' -or [string]$pipelineTaskState.agentStatuses.review_verifier.status -ne 'pending' -or [string]$pipelineTaskState.agentStatuses.pipeline_monitor.status -ne 'pending' -or -not (Test-Path -LiteralPath $firstRemediation.Artifact -PathType Leaf)) { throw 'Pipeline remediation request was not persisted, deduplicated, or projected through Developer, Reviewer, Review Verifier, and Pipeline Monitor as unfinished task work.' }
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
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'knowledge-update.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; entries=@() } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'context-pack.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; artifacts=@() } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $lifecycleTask.TaskRoot 'task-summary.json') -Content (([ordered]@{ taskId=$lifecycleTaskId; status='completed'; completedAtUtc=[DateTime]::UtcNow.ToString('o'); repositories=@('azure-planningspace-ps-excel-agent'); outcomes=@('Synthetic completed-PR closure published.'); decisions=@(); verification=@('Pipeline succeeded and PR completed.'); knowledgeUpdates=@(); artifacts=@('knowledge-update.json','task-summary.json'); residualItems=@() } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$knowledgePublication = & (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -TaskId $lifecycleTaskId -AgentId knowledge_keeper -Summary 'Synthetic completed-PR closure published.' -ConfigPath $pipelineTestConfigPath
$publishedLifecycleTask = Get-Content -LiteralPath $lifecycleTask.TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$knowledgePublication.AgentId -ne 'knowledge_keeper' -or [string]$publishedLifecycleTask.agentStatuses.knowledge_keeper.status -ne 'completed') { throw 'Completed-PR knowledge-only routing did not permit final Knowledge Keeper publication after excluded delivery roles became validated no-op states.' }
$publishedLifecycleTask.closure.status = 'completed'
$publishedLifecycleTask.agentStatuses.requirements_analyst.status = 'completed'
$publishedLifecycleTask.agentStatuses.developer.status = 'skipped'
$publishedLifecycleTask.agentStatuses.reviewer.status = 'skipped'
$publishedLifecycleTask.agentStatuses.review_verifier.status = 'skipped'
$publishedLifecycleTask.agentStatuses.knowledge_keeper.status = 'failed'
Write-Utf8NoBom -Path $lifecycleTask.TaskPath -Content (($publishedLifecycleTask | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$recoveredKnowledgePublication = & (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -TaskId $lifecycleTaskId -AgentId knowledge_keeper -Summary 'Synthetic completed-PR Knowledge Keeper recovery republished.' -ConfigPath $pipelineTestConfigPath
$recoveredLifecycleTask = Get-Content -LiteralPath $lifecycleTask.TaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$recoveredKnowledgePublication.AgentId -ne 'knowledge_keeper' -or [string]$recoveredLifecycleTask.agentStatuses.knowledge_keeper.status -ne 'completed') { throw 'A completed-PR recovery could not republish the validated Knowledge Keeper outcome after closure completed with excluded delivery roles.' }
$recoveredResumePlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $lifecycleTaskId -PreserveArtifactIndex -ConfigPath $pipelineTestConfigPath
if ([bool]$recoveredResumePlan.HasWork -or @($recoveredResumePlan.UnfinishedAgentIds).Count -ne 0 -or 'developer' -notin @($recoveredResumePlan.PreservedAgentIds) -or 'reviewer' -notin @($recoveredResumePlan.PreservedAgentIds) -or 'review_verifier' -notin @($recoveredResumePlan.PreservedAgentIds)) { throw 'Completed-PR knowledge-only recovery treated intentionally skipped Developer, Reviewer, or Review Verifier roles as unfinished.' }
Add-Check -Name 'pull-request-lifecycle' -Detail 'Azure PR status is normalized safely; completed PR routes Pipeline Monitor to Orchestrator, then a persisted decision dispatches and permits initial or recovered final Knowledge Keeper publication'

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
    agentStatuses = [ordered]@{ reviewer = [ordered]@{ status = 'completed' }; review_verifier = [ordered]@{ status = 'completed' } }
}
Write-Utf8NoBom -Path (Join-Path $legacyDeliveryTaskRoot 'task.json') -Content (($legacyDeliveryTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$legacyWorkspaceManifestRoot = Join-Path $legacyDeliveryTaskRoot 'workspaces'
New-Item -ItemType Directory -Path $legacyWorkspaceManifestRoot -Force | Out-Null
$deliveryCommit = ([string](& git -C $deliveryWorkspace rev-parse HEAD)).Trim()
$legacyWorkspaceManifest = [ordered]@{ schemaVersion='2.0.0'; taskId=$legacyDeliveryTaskId; repositoryId=$deliveryRepositoryId; clonePath=[IO.Path]::GetFullPath($deliveryWorkspace); canonicalOrigin='https://example.invalid/synthetic-reviewed-delivery'; baseSha=$deliveryCommit; branch="feature/$deliveryFixtureId"; lifecycle='active'; runId=('e' * 32); leaseId=('f' * 32); createdAtUtc=[DateTime]::UtcNow.ToString('o'); updatedAtUtc=[DateTime]::UtcNow.ToString('o'); manifestPath=(Join-Path $legacyWorkspaceManifestRoot "$deliveryRepositoryId.json") }
Write-Utf8NoBom -Path $legacyWorkspaceManifest.manifestPath -Content (($legacyWorkspaceManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$legacyReviewPath = Join-Path $legacyDeliveryTaskRoot 'review-result.json'
$legacyReview = New-SyntheticReviewResult -TaskId $legacyDeliveryTaskId
Write-Utf8NoBom -Path $legacyReviewPath -Content (($legacyReview | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$legacyVerification = New-SyntheticReviewVerification -TaskId $legacyDeliveryTaskId -ReviewPath $legacyReviewPath
Write-Utf8NoBom -Path (Join-Path $legacyDeliveryTaskRoot 'review-verification.json') -Content (($legacyVerification | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$deliveryPlan = & (Join-Path $root 'scripts\Invoke-ReviewedBranchDelivery.ps1') -TaskId $legacyDeliveryTaskId -RepositoryId $deliveryRepositoryId -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$deliveryPlan.repositoryId -ne $deliveryRepositoryId -or [string]$deliveryPlan.workspace -ne [IO.Path]::GetFullPath($deliveryWorkspace) -or [string]$deliveryPlan.branch -ne "feature/$deliveryFixtureId" -or [string]$deliveryPlan.pushRef -ne "HEAD:refs/heads/feature/$deliveryFixtureId") { throw 'Prepare-only reviewed delivery did not accept the legacy singular repositoryId task scope.' }
Add-Check -Name 'reviewed-branch-delivery-task-workspace' -Detail 'Prepare-only delivery accepts legacy singular repositoryId scope but resolves Git state from its task workspace manifest'

$processReviewTaskId = "process-review-$deliveryFixtureId"
$processReviewTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$processReviewTaskId"
New-Item -ItemType Directory -Path $processReviewTaskRoot -Force | Out-Null
$processReviewTask = [ordered]@{
    taskId = $processReviewTaskId
    selector = 'synthetic-process-review'
    mode = 'manual'
    status = 'review_pending'
    repositoryId = $deliveryRepositoryId
    agentStatuses = [ordered]@{ reviewer = [ordered]@{ status = 'completed' }; review_verifier = [ordered]@{ status = 'pending' }; pipeline_monitor = [ordered]@{ status = 'pending' } }
}
$processFinding = New-SyntheticReviewFinding -Id REV-001 -Category agent-process -CorrectionDirection 'Preserve the synthetic workflow evidence.'
$processReviewResult = New-SyntheticReviewResult -TaskId $processReviewTaskId -ProcessFindings @($processFinding)
Write-Utf8NoBom -Path (Join-Path $processReviewTaskRoot 'task.json') -Content (($processReviewTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$processReviewPath = Join-Path $processReviewTaskRoot 'review-result.json'
Write-Utf8NoBom -Path $processReviewPath -Content (($processReviewResult | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$processReviewContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $processReviewTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$processReviewContinuation.Status -ne 'prepared' -or [string]$processReviewContinuation.NextAgentId -ne 'review_verifier') { throw 'Reviewer outcome bypassed independent verification.' }
$processVerification = New-SyntheticReviewVerification -TaskId $processReviewTaskId -ReviewPath $processReviewPath
Write-Utf8NoBom -Path (Join-Path $processReviewTaskRoot 'review-verification.json') -Content (($processVerification | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $processReviewTaskId -AgentId review_verifier -AgentStatus completed -ConfigPath $deliveryConfigPath | Out-Null
$processVerificationContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $processReviewTaskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$processVerificationContinuation.Status -ne 'prepared' -or [string]$processVerificationContinuation.NextAgentId -ne 'pipeline_monitor') { throw 'An independently verified process-only suggestion incorrectly blocked Pipeline Monitor continuation.' }
Add-Check -Name 'process-suggestion-continuation' -Detail 'Reviewer always hands off to Review Verifier; a verified clean product review then continues to Pipeline Monitor while process suggestions remain visible'

$bypassTaskId = "review-bypass-$deliveryFixtureId"
$bypassTaskRoot = Join-Path $deliveryConfig.runtime.stateRoot "tasks\$bypassTaskId"
New-Item -ItemType Directory -Path $bypassTaskRoot -Force | Out-Null
$bypassTask = [ordered]@{
    taskId=$bypassTaskId; selector='synthetic-review-bypass'; mode='manual'; status='review_pending'; repositoryId=$deliveryRepositoryId
    agentStatuses=[ordered]@{ reviewer=[ordered]@{ status='completed' }; review_verifier=[ordered]@{ status='completed' }; pipeline_monitor=[ordered]@{ status='pending' } }
}
$bypassFinding = [ordered]@{
    id='REV-201'; severity='medium'; category='maintainability'; location='sample.ps1:1'
    evidence='Synthetic evidence.'; impact='Synthetic debt impact.'; correctionDirection='Resolve the synthetic debt.'; decisionStatus='proposed'
}
$bypassReview = New-SyntheticReviewResult -TaskId $bypassTaskId -ProductFindings @($bypassFinding)
Write-Utf8NoBom -Path (Join-Path $bypassTaskRoot 'task.json') -Content (($bypassTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$bypassManifestRoot = Join-Path $bypassTaskRoot 'workspaces'
New-Item -ItemType Directory -Path $bypassManifestRoot -Force | Out-Null
$bypassManifest = [ordered]@{ schemaVersion='2.0.0'; taskId=$bypassTaskId; repositoryId=$deliveryRepositoryId; clonePath=[IO.Path]::GetFullPath($deliveryWorkspace); canonicalOrigin='https://example.invalid/synthetic-reviewed-delivery'; baseSha=$deliveryCommit; branch="feature/$deliveryFixtureId"; lifecycle='active'; runId=('1' * 32); leaseId=('2' * 32); createdAtUtc=[DateTime]::UtcNow.ToString('o'); updatedAtUtc=[DateTime]::UtcNow.ToString('o'); manifestPath=(Join-Path $bypassManifestRoot "$deliveryRepositoryId.json") }
Write-Utf8NoBom -Path $bypassManifest.manifestPath -Content (($bypassManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$bypassReviewPath = Join-Path $bypassTaskRoot 'review-result.json'
Write-Utf8NoBom -Path $bypassReviewPath -Content (($bypassReview | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$bypassVerification = New-SyntheticReviewVerification -TaskId $bypassTaskId -ReviewPath $bypassReviewPath
Write-Utf8NoBom -Path (Join-Path $bypassTaskRoot 'review-verification.json') -Content (($bypassVerification | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$bypassDecision = & (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $bypassTaskId -FindingId REV-201 -Decision bypassed -DecidedBy user -Note 'Accepted as tracked technical debt.' -ConfigPath $deliveryConfigPath
$bypassDebt = Get-Content -LiteralPath (Join-Path $bypassTaskRoot 'tech-debt-items.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$bypassContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $bypassTaskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $deliveryConfigPath
$bypassDeliveryPlan = & (Join-Path $root 'scripts\Invoke-ReviewedBranchDelivery.ps1') -TaskId $bypassTaskId -RepositoryId $deliveryRepositoryId -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$bypassDecision.decision -ne 'bypassed' -or [string]$bypassDecision.techDebtItemId -ne 'TD-REV-201' -or [string]$bypassDecision.reviewArtifactSha256 -ne [string]$bypassVerification.reviewArtifactSha256 -or @($bypassDebt.items | Where-Object { [string]$_.sourceFindingId -eq 'REV-201' -and [string]$_.status -eq 'open' -and [string]$_.reviewArtifactSha256 -eq [string]$bypassVerification.reviewArtifactSha256 }).Count -ne 1 -or [string]$bypassContinuation.NextAgentId -ne 'pipeline_monitor' -or [string]$bypassDeliveryPlan.repositoryId -ne $deliveryRepositoryId) { throw 'A bypassed independently verified Reviewer finding did not create exact-review-bound debt and release only the Pipeline Monitor gate.' }
Add-Check -Name 'review-bypass-technical-debt' -Detail 'Explicit bypass binds the verified finding and task-local debt to the exact review SHA, then permits guarded Pipeline Monitor delivery'

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
        review_verifier = [ordered]@{ status = 'pending' }
        pipeline_monitor = [ordered]@{ status = 'pending' }
        knowledge_keeper = [ordered]@{ status = 'pending' }
        health_check = [ordered]@{ status = 'pending' }
    }
}
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$developerToReviewer = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId developer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$developerToReviewer.Status -ne 'prepared' -or [string]$developerToReviewer.NextAgentId -ne 'reviewer') { throw 'Developer completion at review_pending did not schedule Reviewer.' }
$chainReviewPath = Join-Path $chainMatrixRoot 'review-result.json'
$chainReview = New-SyntheticReviewResult -TaskId $chainMatrixTaskId
Write-Utf8NoBom -Path $chainReviewPath -Content (($chainReview | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$chainMatrixTask.agentStatuses.reviewer.status = 'completed'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$reviewerToVerifier = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$reviewerToVerifier.Status -ne 'prepared' -or [string]$reviewerToVerifier.NextAgentId -ne 'review_verifier') { throw 'Reviewer completion did not schedule the independent Review Verifier.' }

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
$chainMatrixTask.agentStatuses.health_check.status = 'completed'
$chainMatrixTask.agentStatuses.developer.status = 'pending'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$healthToDeveloper = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId health_check -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$healthToDeveloper.Status -ne 'prepared' -or [string]$healthToDeveloper.NextAgentId -ne 'developer') { throw 'Completed Health Check did not resume the first pending delivery role.' }

$chainMatrixTask.status = 'interrupted'
$chainMatrixTask.agentStatuses.knowledge_keeper.status = 'completed'
$chainMatrixTask.agentStatuses.developer.status = 'completed'
$chainMatrixTask.agentStatuses.reviewer.status = 'pending'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$keeperToUnfinished = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId knowledge_keeper -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$keeperToUnfinished.Status -ne 'prepared' -or [string]$keeperToUnfinished.NextAgentId -ne 'reviewer') { throw 'Scoped Knowledge Keeper completion did not return to the first unfinished delivery role.' }

$chainMatrixTask.status = 'interrupted'
$chainMatrixTask.agentStatuses.orchestrator = [ordered]@{ status = 'completed' }
$chainMatrixTask.agentStatuses.requirements_analyst.status = 'pending'
$chainMatrixTask.agentStatuses.developer.status = 'pending'
$chainMatrixTask.agentStatuses.reviewer.status = 'pending'
$chainMatrixTask.agentStatuses.review_verifier.status = 'pending'
$chainMatrixTask.agentStatuses.pipeline_monitor.status = 'pending'
$chainMatrixTask.agentStatuses.knowledge_keeper.status = 'pending'
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$orchestratorToRequirements = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId orchestrator -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$orchestratorToRequirements.Status -ne 'prepared' -or [string]$orchestratorToRequirements.NextAgentId -ne 'requirements_analyst') { throw 'Initial or resumed Orchestrator completion did not schedule the first pending delivery role.' }

$chainMatrixTask.status = 'review_pending'
$chainMatrixTask.agentStatuses.reviewer.status = 'completed'
$chainMatrixTask.agentStatuses.review_verifier.status = 'completed'
$humanGateFinding = New-SyntheticReviewFinding -Id REV-099 -Category correctness -CorrectionDirection 'Resolve the synthetic human-gate finding.'
$humanGateReview = New-SyntheticReviewResult -TaskId $chainMatrixTaskId -ReviewedRevision 'human-gate-v1' -ProductFindings @($humanGateFinding)
Write-Utf8NoBom -Path $chainReviewPath -Content (($humanGateReview | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$humanGateVerification = New-SyntheticReviewVerification -TaskId $chainMatrixTaskId -ReviewPath $chainReviewPath
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'review-verification.json') -Content (($humanGateVerification | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $chainMatrixRoot 'task.json') -Content (($chainMatrixTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$verifierHumanGate = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $chainMatrixTaskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$verifierHumanGate.Status -ne 'review-pending') { throw 'Verified human-decision gate was misclassified as a failed or abnormal chain stop.' }

$approvedHandoffTaskId = 'approved-handoff-' + $deliveryFixtureId
$approvedHandoffRoot = Join-Path $deliveryConfig.runtime.stateRoot ('tasks\' + $approvedHandoffTaskId)
New-Item -ItemType Directory -Path $approvedHandoffRoot -Force | Out-Null
$approvedHandoffTask = [ordered]@{ taskId=$approvedHandoffTaskId; selector='synthetic-approved-handoff'; mode='manual'; status='review_pending'; repositoryId=$deliveryRepositoryId; agentStatuses=[ordered]@{ reviewer=[ordered]@{ status='completed' }; review_verifier=[ordered]@{ status='completed' }; developer=[ordered]@{ status='completed' }; pipeline_monitor=[ordered]@{ status='pending' }; orchestrator=[ordered]@{ status='completed' } } }
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'task.json') -Content (($approvedHandoffTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedProductFinding = New-SyntheticReviewFinding -Id REV-101 -Category correctness -CorrectionDirection 'Implement approved product coverage.'
$approvedProcessFinding = New-SyntheticReviewFinding -Id REV-102 -Category agent-process -CorrectionDirection 'Repair approved workflow fingerprints.'
$approvedReview = New-SyntheticReviewResult -TaskId $approvedHandoffTaskId -ProductFindings @($approvedProductFinding) -ProcessFindings @($approvedProcessFinding)
$approvedReviewPath = Join-Path $approvedHandoffRoot 'review-result.json'
Write-Utf8NoBom -Path $approvedReviewPath -Content (($approvedReview | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
$approvedVerification = New-SyntheticReviewVerification -TaskId $approvedHandoffTaskId -ReviewPath $approvedReviewPath
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'review-verification.json') -Content (($approvedVerification | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $approvedHandoffTaskId -FindingId REV-101 -Decision approved -DecidedBy user -ConfigPath $deliveryConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $approvedHandoffTaskId -FindingId REV-102 -Decision approved -DecidedBy user -ConfigPath $deliveryConfigPath | Out-Null
$approvedHandoff = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $approvedHandoffTaskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $deliveryConfigPath
$approvedDeveloperBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $approvedHandoffTaskId -AgentId developer -ConfigPath $deliveryConfigPath
$approvedOrchestratorBatch = & (Join-Path $root 'scripts\Get-AgentCommentBatch.ps1') -TaskId $approvedHandoffTaskId -AgentId orchestrator -ConfigPath $deliveryConfigPath
if ([string]$approvedHandoff.NextAgentId -ne 'developer' -or @($approvedDeveloperBatch.comments | Where-Object { @($_.evidence) -contains 'review-finding:REV-101' -and @($_.evidence) -contains 'decision:approved' -and [string]$_.text -match 'Implement approved product coverage' }).Count -ne 1 -or @($approvedOrchestratorBatch.comments | Where-Object { @($_.evidence) -contains 'review-finding:REV-102' -and @($_.evidence) -contains 'decision:approved' -and [string]$_.text -match 'Repair approved workflow fingerprints' }).Count -ne 1) { throw 'Approved product and process findings were not durably routed with their correction direction.' }
$approvedHandoffTask = Get-Content -LiteralPath (Join-Path $approvedHandoffRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$approvedHandoffTask.agentStatuses.developer.status = 'completed'
Write-Utf8NoBom -Path (Join-Path $approvedHandoffRoot 'task.json') -Content (($approvedHandoffTask | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$approvedProcessPriority = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $approvedHandoffTaskId -CompletedAgentId developer -PrepareOnly -ConfigPath $deliveryConfigPath
if ([string]$approvedProcessPriority.NextAgentId -ne 'orchestrator') { throw 'An approved process workflow input did not prioritize Orchestrator before the normal post-Developer Reviewer transition.' }
Add-Check -Name 'automatic-chain-transition-matrix' -Detail 'Requirements to Developer, Developer to Reviewer, Reviewer to independent Verifier, Pipeline remediation to Developer, and scoped Knowledge Keeper return are host-driven across valid task gates'

$orphanTaskId = 'orphan-continuation-' + $deliveryFixtureId
$orphanRoot = Join-Path $deliveryConfig.runtime.stateRoot ('tasks\' + $orphanTaskId)
New-Item -ItemType Directory -Path $orphanRoot -Force | Out-Null
$orphanTask = [ordered]@{ taskId=$orphanTaskId; selector='synthetic-orphan-continuation'; mode='manual'; status='interrupted'; repositoryId=$deliveryRepositoryId; agentStatuses=[ordered]@{ requirements_analyst=[ordered]@{ status='completed' }; developer=[ordered]@{ status='completed' }; reviewer=[ordered]@{ status='completed' }; review_verifier=[ordered]@{ status='completed' }; pipeline_monitor=[ordered]@{ status='completed' }; knowledge_keeper=[ordered]@{ status='completed' } } }
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
$orchestratorContinuationScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-OrchestratorContinuation.ps1') -Raw -Encoding UTF8
$continuationRecoveryScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Repair-AgentContinuations.ps1') -Raw -Encoding UTF8
$publishOutcomeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -Raw -Encoding UTF8
$developerPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\developer.md') -Raw -Encoding UTF8
$healthRecoverySchema = Get-Content -LiteralPath (Join-Path $root 'config\schemas\health-recovery-result.schema.json') -Raw -Encoding UTF8
if ($knowledgePrompt -notmatch 'Never cyclically poll' -or $knowledgePrompt -notmatch 'explicit agent knowledge or skill requests') { throw 'Knowledge Keeper is not pull-based or still permits subagent polling.' }
if ($taskProtocol -notmatch 'Publish-AgentOutcome.ps1' -or $taskProtocol -notmatch 'agent-checkpoints' -or $taskProtocol -notmatch 'autonomous bounded work blocks' -or $taskProtocol -notmatch 'Get-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Acknowledge-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Request-OrchestratorCommentRouting.ps1' -or $taskProtocol -notmatch 'same agent invocation') { throw 'Private checkpoint, autonomous work-block, successful outcome, end-of-block comment, or authority-handoff contract is missing.' }
if (-not [bool]$config.workflow.orchestration.forwardOutOfScopeComments -or -not [bool]$config.workflow.orchestration.autoDispatchForwardedComments -or $continueChainScript -notmatch 'agent-routing-request' -or $continueChainScript -notmatch 'workflow-input-routed') { throw 'Automatic out-of-scope and approved-process input routing is not enabled end to end.' }
if ($orchestratorContinuationScript -notmatch 'OrchestratorAuthorized' -or $workflowScript -notmatch 'Invoke-OrchestratorContinuation.ps1' -or $publishOutcomeScript -notmatch 'TargetAgentId orchestrator' -or $continueChainScript -notmatch 'Actor orchestrator -Type routing-decision') { throw 'Role outcomes can bypass the deterministic Orchestrator transition boundary.' }
if (@([regex]::Matches($workflowScript, 'Publish-AgentOutcome\.ps1''\) -TaskId ''\$TaskId'' -AgentId orchestrator')).Count -lt 2 -or $workflowScript -notmatch 'A final response or activity entry does not make Orchestrator terminal' -or $workflowScript -notmatch 'Final prose or an activity entry is not terminal publication') { throw 'Orchestrator can return after routing without mandatory terminal outcome publication.' }
if ($continueChainScript -notmatch 'reevaluateDeveloperGate' -or $continueChainScript -notmatch 'reevaluatePipelineGate') { throw 'Developer review continuation or Pipeline remediation continuation is blocked by a stale task gate.' }
if ($continueChainScript -notmatch 'transitionCounts' -or $continueChainScript -notmatch 'maxTransitionRepeats' -or $continueChainScript -notmatch 'automatic_chain_guard' -or $continueChainScript -notmatch 'Start-AgentHealthRecovery.ps1') { throw 'Automatic continuation loop limits do not fail closed into Health Check.' }
if ($continueChainScript -notmatch 'pipeline_authority_handoff' -or $workflowScript -notmatch 'preservePipelineNonSuccess') { throw 'A non-success pipeline can still close the task or fail to hand unknown ownership to Orchestrator.' }
if ($continueChainScript -notmatch 'automatic-continuation\.lock' -or $continueChainScript -notmatch '''health_check''\s*\{' -or $publishOutcomeScript -notmatch 'continuation-requested' -or $publishOutcomeScript -notmatch '''health_check''' -or $continuationRecoveryScript -notmatch 'continuation-reconciled' -or $continuationRecoveryScript -notmatch 'recoveryGraceSeconds' -or $continuationRecoveryScript -notmatch 'Test-ExactHealthRepair' -or $continuationRecoveryScript -notmatch 'health-repair-required') { throw 'Durable, idempotent continuation recovery or the failed-agent Health Check gate is incomplete.' }
if ($dashboardHtml -notmatch 'finishing its current work block' -or $dashboardClient -notmatch 'no restart is needed') { throw 'Dashboard does not explain automatic end-of-block comment consumption.' }
if ($healthPrompt -notmatch 'health-diagnostic-context.json' -or $healthRecoveryScript -notmatch 'Get-BoundedTextTail' -or $healthRecoveryScript -notmatch 'workflowLogTailLines') { throw 'Health Check bounded diagnostic context is incomplete.' }
if ($healthPrompt -notmatch 'diagnosis is not a terminal outcome' -or $healthRecoveryScript -notmatch 'existingDiagnosis' -or $healthRecoveryScript -notmatch 'health-repair-routing.json' -or $healthRecoverySchema -notmatch 'routeAgentId' -or $healthRecoverySchema -notmatch 'repairOwner') { throw 'Health Check repair-or-route contract is incomplete.' }
if ($orchestratorPrompt -notmatch 'explicit source-controlled ecosystem maintenance go to health_check' -or $orchestratorPrompt -notmatch 'Do not ask to expand a product task for Developer' -or $healthPrompt -notmatch 'explicit source-controlled ecosystem change' -or $healthPrompt -notmatch 'Do not redirect ecosystem source changes to Developer') { throw 'Ecosystem source maintenance is not owned end to end by Health Check.' }
if ($orchestratorPrompt -notmatch 'diagnose or inspect a pipeline failure and then fix' -or $orchestratorPrompt -notmatch 'pipeline-only` is read-only observation') { throw 'Pipeline investigation plus an explicit source fix can still be misclassified as pipeline-only.' }
if ($workflowScript -notmatch 'health_recovery_handoff' -or $workflowScript -notmatch 'DiagnosisPath' -or $workflowScript -notmatch 'repairOwner' -or $workflowScript -notmatch 'requiresUserInput' -or $workflowScript -notmatch 'health_diagnosis_recovery') { throw 'A waiting or completed non-user-input Health Check diagnosis is not handed to automatic recovery.' }
if ($continueChainScript -notmatch "PSObject\.Properties\['repositoryIds'\]" -or $continueChainScript -notmatch "PSObject\.Properties\['repositoryId'\]") { throw 'Automatic continuation does not normalize legacy singular repositoryId task scope.' }
if ($healthPrompt -notmatch 'restart exactly the affected agentId' -or $taskProtocol -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Health Check prompt contract does not restrict post-repair execution to the affected agent.' }
if ($healthTargetedResumeScript -notmatch 'TargetAgentId = \$targetAgentId' -or $healthTargetedResumeScript -notmatch 'HealthRecoveryRetry = \$true' -or $healthTargetedResumeScript -notmatch 'maxAttemptsPerFailureSignature' -or $healthTargetedResumeScript -notmatch 'RecoveryEvidencePath') { throw 'Health Check targeted-resume launcher is missing its target, validation, or retry-loop guard.' }
if ($workflowScript -notmatch 'HealthRecoveryRetry' -or $workflowScript -notmatch '-not \$HealthRecoveryRetry' -or $healthRecoveryScript -notmatch 'Start-HealthTargetedResume.ps1') { throw 'Workflow and Health recovery are not wired to the one-shot targeted retry.' }
if ($healthRecoveryScript -notmatch 'RecoveryDepth' -or $healthRecoveryScript -notmatch 'health_recovery_followup' -or $healthRecoveryScript -notmatch 'Write-AgentFailure.ps1' -or $healthRecoveryScript -notmatch "targetedResume.Status -eq 'failed'") { throw 'A failure exposed by post-repair targeted resume is not returned to bounded Health recovery.' }
if ($resumeScript -notmatch 'ChangedArtifactNames' -or $resumeScript -notmatch 'resume-artifact-index.json' -or $resumeScript -notmatch 'agentFingerprints' -or $resumeScript -notmatch 'shareableArtifacts' -or $resumeScript -notmatch "-ne 'completed'" -or $workflowScript -notmatch 'Get-AgentResumePlan\.ps1.+-PreserveArtifactIndex') { throw 'Per-agent resume artifact fingerprinting, completed-outcome filtering, or non-consuming bookkeeping is incomplete.' }
if ($publishOutcomeScript -notmatch 'Test-AgentOutcomeArtifact\.ps1' -or $developerPrompt -notmatch 'New-DeveloperPublicationEvidence\.ps1' -or $developerPrompt -notmatch 'publicationEvidenceId') { throw 'Developer final-command evidence generation or semantic outcome validation is not wired end to end.' }

$outcomeValidationRoot = Join-Path $OutputRoot ('outcome-validation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outcomeValidationRoot -Force | Out-Null
$outcomeGitRoot = Join-Path $outcomeValidationRoot 'workspace'
$outcomeRemoteRoot = Join-Path $outcomeValidationRoot 'remote.git'
New-Item -ItemType Directory -Path $outcomeGitRoot -Force | Out-Null
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('init')
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('config','user.email','ecosystem-test@example.invalid')
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('config','user.name','Ecosystem Test')
Write-Utf8NoBom -Path (Join-Path $outcomeGitRoot 'baseline.txt') -Content "baseline$([Environment]::NewLine)"
New-Item -ItemType Directory -Path (Join-Path $outcomeGitRoot 'tests') -Force | Out-Null
Write-Utf8NoBom -Path (Join-Path $outcomeGitRoot 'tests\Synthetic.Tests.ps1') -Content "Describe 'Synthetic publication evidence' { It 'passes' { 1 | Should Be 1 } }$([Environment]::NewLine)"
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('add','baseline.txt','tests/Synthetic.Tests.ps1')
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('commit','-m','baseline')
$null = @(& git init --bare $outcomeRemoteRoot 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize synthetic outcome-validation remote.' }
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('remote','add','origin',$outcomeRemoteRoot)
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('push','-u','origin','HEAD')
Write-Utf8NoBom -Path (Join-Path $outcomeGitRoot 'ahead.txt') -Content "ahead$([Environment]::NewLine)"
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('add','ahead.txt')
$null = Invoke-SchedulerTestGit -Workspace $outcomeGitRoot -Arguments @('commit','-m','ahead')
$outcomeConfigPath = Join-Path $outcomeValidationRoot 'agents.json'
$outcomeConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$outcomeConfig.runtime.stateRoot = Join-Path $outcomeValidationRoot 'state'
Write-Utf8NoBom -Path $outcomeConfigPath -Content (($outcomeConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$outcomeTaskId = 'synthetic-outcome-validation'
$outcomeTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $outcomeTaskId -TaskSelector synthetic-outcome-validation -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $outcomeConfigPath
$generatedEvidence = & (Join-Path $root 'scripts\New-DeveloperPublicationEvidence.ps1') -TaskId $outcomeTaskId -Workspace $outcomeGitRoot -PesterPath @('tests\Synthetic.Tests.ps1') -ConfigPath $outcomeConfigPath
$publicationEvidencePath = [string]$generatedEvidence.EvidencePath
$publicationEvidence = Get-Content -LiteralPath $publicationEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
$liveBranch = [string]$publicationEvidence.branch
$liveHead = [string]$publicationEvidence.headCommit
$liveParts = @([int]$publicationEvidence.branchDivergence.behindCount,[int]$publicationEvidence.branchDivergence.aheadCount)
$pesterRecord = @($publicationEvidence.pester) | Select-Object -First 1
$validImplementation = [ordered]@{
    taskId='synthetic-outcome-validation'; branch=$liveBranch; commit=$liveHead; commitState="clean worktree; branch is $([int]$liveParts[1]) local commits ahead"
    tests=@(
        [ordered]@{ command=[string]$pesterRecord.command; result=[string]$pesterRecord.result; evidence="Passed $([int]$pesterRecord.passedCount)/$([int]$pesterRecord.totalCount) from the final command."; publicationEvidenceId=[string]$pesterRecord.evidenceId },
        [ordered]@{ command='git status --porcelain and git rev-list'; result='passed'; evidence="Branch is $([int]$liveParts[1]) local commits ahead."; publicationEvidenceId='git-branch-divergence' }
    )
}
$implementationPath = Join-Path $outcomeTask.TaskRoot 'implementation-result.json'
Write-Utf8NoBom -Path $implementationPath -Content (($validImplementation | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId 'synthetic-outcome-validation' -AgentId developer -ArtifactName 'implementation-result.json' -Path $implementationPath -TaskRoot $outcomeTask.TaskRoot
$contradictoryCount = $validImplementation | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$contradictoryCount.tests[0].result = 'passed 6/6'
Write-Utf8NoBom -Path $implementationPath -Content (($contradictoryCount | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$countRejected = $false
try { & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId 'synthetic-outcome-validation' -AgentId developer -ArtifactName 'implementation-result.json' -Path $implementationPath -TaskRoot $outcomeTask.TaskRoot }
catch { $countRejected = $_.Exception.Message -match 'contradictory result/evidence counts' }
$contradictoryBranch = $validImplementation | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$contradictoryBranch.commitState = "clean worktree; branch is $([int]$liveParts[1] + 1) local commits ahead"
Write-Utf8NoBom -Path $implementationPath -Content (($contradictoryBranch | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
$branchRejected = $false
try { & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId 'synthetic-outcome-validation' -AgentId developer -ArtifactName 'implementation-result.json' -Path $implementationPath -TaskRoot $outcomeTask.TaskRoot }
catch { $branchRejected = $_.Exception.Message -match 'contradictory branch-divergence evidence' }
if (-not $countRejected -or -not $branchRejected) { throw 'Developer outcome validation accepted contradictory Pester-count or branch-divergence fields.' }
Add-Check -Name 'developer-outcome-final-command-evidence' -Detail 'Valid final-command evidence passes; contradictory Pester counts and branch divergence are rejected deterministically'

$fingerprintRoot = Join-Path $OutputRoot ('resume-fingerprint-' + [guid]::NewGuid().ToString('N'))
$fingerprintConfigPath = Join-Path $fingerprintRoot 'agents.json'
$fingerprintConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fingerprintConfig.runtime.stateRoot = Join-Path $fingerprintRoot 'state'
Write-Utf8NoBom -Path $fingerprintConfigPath -Content (($fingerprintConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
$fingerprintTaskId = 'resume-fingerprint-' + [guid]::NewGuid().ToString('N')
$fingerprintTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $fingerprintTaskId -TaskSelector synthetic-resume-fingerprint -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fingerprintConfigPath
$null = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId developer -ConfigPath $fingerprintConfigPath
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'implementation-plan.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"scope`":[]}$([Environment]::NewLine)"
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'developer-publication-evidence.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"status`":`"synthetic`"}$([Environment]::NewLine)"
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'implementation-result.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"status`":`"implemented`"}$([Environment]::NewLine)"
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $fingerprintTaskId -AgentId developer -AgentStatus completed -Stage developer-completed -Message 'Synthetic Developer outcome changed its implementation artifacts.' -ConfigPath $fingerprintConfigPath | Out-Null
$postDeveloperBookkeepingPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -PreserveArtifactIndex -ConfigPath $fingerprintConfigPath
$reviewerStartupPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId reviewer -ConfigPath $fingerprintConfigPath
$reviewerRepeatedPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId reviewer -ConfigPath $fingerprintConfigPath
$developerArtifacts = @('implementation-plan.json','developer-publication-evidence.json','implementation-result.json')
if (@($developerArtifacts | Where-Object { $_ -notin @($postDeveloperBookkeepingPlan.ChangedArtifactNames) }).Count -or @($developerArtifacts | Where-Object { $_ -notin @($reviewerStartupPlan.ChangedArtifactNames) }).Count -or @($developerArtifacts | Where-Object { $_ -notin @($reviewerRepeatedPlan.UnchangedArtifactNames) }).Count) { throw 'Developer-to-Reviewer continuation consumed changed artifact fingerprints during post-Developer bookkeeping.' }
Add-Check -Name 'developer-reviewer-resume-fingerprints' -Detail 'Post-Developer bookkeeping preserves the fingerprint baseline; Reviewer startup receives changed implementation artifacts and then advances the index once'
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'review-decisions.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"decisions`":[]}$([Environment]::NewLine)"
$null = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId pipeline_monitor -ConfigPath $fingerprintConfigPath
Write-Utf8NoBom -Path (Join-Path $fingerprintTask.TaskRoot 'review-decisions.json') -Content "{`"taskId`":`"$fingerprintTaskId`",`"decisions`":[{`"findingId`":`"REV-015`",`"decision`":`"bypassed`"},{`"findingId`":`"REV-016`",`"decision`":`"bypassed`"}]}$([Environment]::NewLine)"
$healthStartupPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId health_check -ConfigPath $fingerprintConfigPath
$pipelineAfterHealthPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId pipeline_monitor -ConfigPath $fingerprintConfigPath
$pipelineRepeatedPlan = & (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -TaskId $fingerprintTaskId -TargetAgentId pipeline_monitor -ConfigPath $fingerprintConfigPath
if ('review-decisions.json' -notin @($healthStartupPlan.ChangedArtifactNames) -or 'review-decisions.json' -notin @($pipelineAfterHealthPlan.ChangedArtifactNames) -or 'review-decisions.json' -notin @($pipelineRepeatedPlan.UnchangedArtifactNames)) { throw 'Health Check consumed Pipeline Monitor''s changed authoritative review-decisions artifact.' }
Add-Check -Name 'health-pipeline-resume-fingerprints' -Detail 'Health Check and Pipeline Monitor maintain independent artifact baselines; Health Check cannot consume changed review decisions before Pipeline Monitor starts'
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
foreach ($agentId in @('knowledge_keeper','developer','reviewer','review_verifier')) {
    $engineeringAgent = @($config.agents | Where-Object id -eq $agentId) | Select-Object -First 1
    if (-not $engineeringAgent) { throw "Engineering-guidance agent is missing: $agentId" }
    $skillPaths = @($engineeringAgent.skillPaths | ForEach-Object { [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$_)) })
    foreach ($skillName in $engineeringSkills) {
        if ($skillPaths -notcontains $skillName) { throw "$agentId is missing required engineering skill: $skillName" }
    }
}
Add-Check -Name 'engineering-skill-routing' -Detail 'Knowledge Keeper, Developer, Reviewer, and Review Verifier share common plus .NET/JS/React guidance'

$healthAgent = @($config.agents | Where-Object id -eq 'health_check') | Select-Object -First 1
if (-not $healthAgent) { throw 'Health Check Agent is missing from the canonical configuration.' }
$healthResponsibilities = @($healthAgent.responsibilities) -join [Environment]::NewLine
if ($healthResponsibilities -notmatch 'source-controlled changes to the development-agent ecosystem' -or $healthResponsibilities -notmatch 'bounded ecosystem_recovery plan') { throw 'Health Check canonical responsibilities do not include ecosystem source maintenance.' }
if ((@($config.agents | Where-Object id -eq 'orchestrator' | Select-Object -ExpandProperty responsibilities) -join [Environment]::NewLine) -notmatch 'source-controlled ecosystem scripts') { throw 'Orchestrator role directory does not route ecosystem source maintenance to Health Check.' }
if ([string]$healthAgent.sandboxMode -ne 'read-only') { throw 'Health Check Agent must remain read-only inside product workflows.' }
if ([bool]$config.health.automaticRecovery.allowProductCodeChanges -or [bool]$config.health.automaticRecovery.allowExternalWrites) { throw 'Automatic health recovery boundary is unsafe.' }
if (-not [bool]$config.health.automaticRecovery.allowEcosystemSourceChanges -or -not [bool]$config.health.automaticRecovery.preserveDirtyWorktreeChanges -or -not [bool]$config.health.automaticRecovery.commitVerifiedRepairs -or $healthRecoveryScript -notmatch 'health_recovery_commit' -or $healthRecoveryScript -notmatch 'git -C \$workspace commit') { throw 'Validated ecosystem source repairs are not preservation- and repair-commit capable through the trusted host.' }
if (-not [bool]$config.health.automaticRecovery.pushVerifiedRepairs -or [string]$config.health.automaticRecovery.pushRemote -ne 'origin' -or [string]$config.health.automaticRecovery.pushRemoteUrl -ne 'https://github.com/GINomad/development-agent-ecosystem.git') { throw 'Verified Health repair delivery is not bound to the exact canonical ecosystem origin.' }
if ($healthRecoveryScript -notmatch 'Publish-VerifiedHealthRepair' -or $healthRecoveryScript -notmatch 'remote get-url \$remote' -or $healthRecoveryScript -notmatch 'push --set-upstream \$remote \$pushRef' -or $healthRecoveryScript -notmatch 'ls-remote --heads \$remote' -or $healthRecoveryScript -notmatch '\$remoteCommit -ne \$Commit' -or $healthRecoveryScript -notmatch '\$branch -in @\(''main'',''master''\)' -or $healthRecoveryScript -notmatch 'health_recovery_push') { throw 'Trusted-host Health delivery lacks exact remote, branch, push, SHA-verification, or activity gates.' }
if ($healthRecoveryScript -match '(?i)git[^\r\n]*push[^\r\n]*(--force|\s-f\s|refs/tags/)') { throw 'Health repair delivery must never force-push or publish tags.' }
$healthPushAuthorization = @($config.gates.externalWrites.standingAuthorizations | Where-Object { [string]$_.operation -eq 'git-push' -and [string]$_.policy -eq 'health.automaticRecovery.pushVerifiedRepairs' })
if ($healthPushAuthorization.Count -ne 1 -or $healthPrompt -notmatch 'configured `origin` branch policy' -or $healthPrompt -notmatch 'recovery model itself must not commit or push') { throw 'Health verified-repair standing authorization or model/host separation is incomplete.' }
if ($healthRecoveryScript -notmatch '\$gitAddExitCode' -or $healthRecoveryScript -notmatch '\$ErrorActionPreference\s*=\s*''Continue''' -or $healthRecoveryScript -match '& git -C \$workspace add --all -- \.\s*\r?\n\s*if \(\$LASTEXITCODE') { throw 'Health recovery commit treats non-fatal Git stderr warnings as failures.' }
if ([string]$config.health.automaticRecovery.sandboxMode -ne 'workspace-write') { throw 'The retained non-default Health fallback sandbox must remain workspace-write.' }
if ([string]$config.runtime.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$config.runtime.elevatedFallback.useByDefault -or [bool]$config.runtime.elevatedFallback.requiresDashboardApproval) { throw 'Workflow host-compatible execution must be selected by default under standing authorization.' }
if ([string]$config.health.automaticRecovery.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$config.health.automaticRecovery.elevatedFallback.useByDefault -or [bool]$config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Health host-compatible execution must be selected by default under standing authorization.' }
$preservationScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Save-EcosystemRecoveryBaseline.ps1') -Raw -Encoding UTF8
if ($healthRecoveryScript -notmatch 'Save-EcosystemRecoveryBaseline.ps1' -or $healthRecoveryScript -notmatch 'preExistingWorktreeChanges' -or $preservationScript -notmatch 'git -C \$resolvedWorkspace add --all -- \.' -or $preservationScript -notmatch 'preservationCommit') { throw 'Health Check recovery does not commit and expose the complete dirty ecosystem baseline before repair.' }
$preservationFixture = Join-Path $OutputRoot ('health-preservation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $preservationFixture -Force | Out-Null
& git -C $preservationFixture init -b main | Out-Null
& git -C $preservationFixture config user.email 'ecosystem-test@local.invalid'
& git -C $preservationFixture config user.name 'Ecosystem Test'
[IO.File]::WriteAllText((Join-Path $preservationFixture 'tracked.txt'), 'before', (New-Object Text.UTF8Encoding($false)))
& git -C $preservationFixture add -- tracked.txt
& git -C $preservationFixture commit -m 'initial' | Out-Null
[IO.File]::WriteAllText((Join-Path $preservationFixture 'tracked.txt'), 'after', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $preservationFixture 'untracked.txt'), 'new', (New-Object Text.UTF8Encoding($false)))
$preservationArtifactPath = Join-Path $OutputRoot ('health-preservation-artifact-' + [guid]::NewGuid().ToString('N') + '.json')
$preservedBaselineResults = @(& (Join-Path $root 'scripts\Save-EcosystemRecoveryBaseline.ps1') -Workspace $preservationFixture -TaskId 'task-preservation' -FailureSignature ('a' * 64) -ArtifactPath $preservationArtifactPath -RepairBranchPrefix 'health-recovery' 2>&1)
if ($preservedBaselineResults.Count -ne 1 -or $preservedBaselineResults[0] -is [string]) { throw 'Dirty baseline preservation emitted unstructured output before its result object.' }
$preservedBaseline = $preservedBaselineResults[0]
$preservedArtifact = Get-Content -LiteralPath $preservationArtifactPath -Raw -Encoding UTF8 | ConvertFrom-Json
$preservedHead = ([string](& git -C $preservationFixture rev-parse HEAD)).Trim()
$preservedFiles = @(& git -C $preservationFixture show --pretty= --name-only HEAD)
if ([string]$preservedBaseline.Status -ne 'preserved' -or [string]$preservedBaseline.Branch -notmatch '^health-recovery/' -or [string]$preservedBaseline.Commit -ne $preservedHead -or [string]$preservedArtifact.preservationCommit -ne $preservedHead -or @(& git -C $preservationFixture status --porcelain=v1).Count -or $preservedFiles -notcontains 'tracked.txt' -or $preservedFiles -notcontains 'untracked.txt') { throw 'Dirty baseline preservation did not create a clean, separate, complete commit on a non-base branch.' }
Add-Check -Name 'health-dirty-baseline-preservation' -Detail "tracked and untracked changes preserved as $preservedHead before repair"
$targetedResumeConfig = $config.health.automaticRecovery.targetedResume
if (-not [bool]$targetedResumeConfig.enabled -or -not [bool]$targetedResumeConfig.requireSuccessfulRepair -or [int]$targetedResumeConfig.maxAttemptsPerFailureSignature -ne 1) { throw 'Health Check targeted resume must require validated repair and permit exactly one attempt.' }
if (@($targetedResumeConfig.allowedAgentIds) -contains 'health_check' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'requirements_analyst' -or @($targetedResumeConfig.allowedAgentIds) -notcontains 'developer') { throw 'Health Check targeted resume allowlist is unsafe or incomplete.' }
foreach ($healthScript in @('Invoke-EcosystemHealthCheck.ps1','Write-AgentFailure.ps1','Save-EcosystemRecoveryBaseline.ps1','Start-AgentHealthRecovery.ps1','Start-HealthTargetedResume.ps1','Invoke-GuardedCodex.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$healthScript") -PathType Leaf)) { throw "Health recovery script is missing: $healthScript" }
}
Add-Check -Name 'health-recovery-contract' -Detail "automatic=$($config.health.automaticRecovery.enabled); ecosystemWrites=$($config.health.automaticRecovery.allowEcosystemSourceChanges); preservationCommit=$($config.health.automaticRecovery.preserveDirtyWorktreeChanges); repairCommit=$($config.health.automaticRecovery.commitVerifiedRepairs); exactOriginPush=$($config.health.automaticRecovery.pushVerifiedRepairs); attempts=$($config.health.automaticRecovery.maxAttemptsPerFailureSignature); targetedAttempts=$($targetedResumeConfig.maxAttemptsPerFailureSignature); failedAgentOnly=true; elevated=standing-default; productWrites=false; modelExternalWrites=false"

$knowledgeAgent = @($config.agents | Where-Object id -eq 'knowledge_keeper') | Select-Object -First 1
$knowledgeResponsibilities = @($knowledgeAgent.responsibilities) -join [Environment]::NewLine
$knowledgePrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\knowledge-keeper.md') -Raw -Encoding UTF8
$knowledgeSkill = Get-Content -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills\keep-task-knowledge\SKILL.md') -Raw -Encoding UTF8
$globalStandardsPath = Resolve-EcosystemPath -Value ([string]$config.knowledge.globalStandardsPath) -Config $config -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $globalStandardsPath -PathType Leaf)) { throw 'Configured global coding standards file is missing.' }
$globalStandards = Get-Content -LiteralPath $globalStandardsPath -Raw -Encoding UTF8
if ($knowledgeResponsibilities -notmatch 'every confirmed review comment about code organization' -or $knowledgeResponsibilities -notmatch 'business, domain, API, integration' -or $knowledgePrompt -notmatch 'every confirmed human review comment about code organization' -or $knowledgePrompt -notmatch 'Business rules, domain behavior, API contracts' -or $knowledgePrompt -notmatch 'always add the configured global coding standards file to `acceptedKnowledge`' -or $knowledgePrompt -notmatch 'configured versioned knowledge roots' -or $knowledgePrompt -notmatch 'bypassed, deferred, rejected, unresolved' -or $knowledgeSkill -notmatch 'global or technology-scoped standard' -or $knowledgeSkill -notmatch 'business, domain, API, integration' -or $developerPrompt -notmatch 'global coding standards to every repository' -or $reviewerPrompt -notmatch 'global coding standards in every repository' -or $workflowRunner -notmatch 'Global coding standards \(apply to every repository\)' -or $workflowRunner -notmatch 'GlobalStandardsPath') { throw 'Knowledge scope classification or global standards delivery is incomplete.' }
if ($globalStandards -notmatch 'Use braces for every `if`' -or $globalStandards -notmatch '`public static`' -or $globalStandards -notmatch '`private static`' -or $globalStandards -notmatch 'f806355b73d3493fbcd171d51fa352ca' -or $globalStandards -notmatch 'a5bae0d26ac94b8e8f1984ce8b361d7c' -or $globalStandards -notmatch 'Business rules, domain behavior, API contracts') { throw 'Global review-derived style standards or their evidence are incomplete.' }
Add-Check -Name 'review-derived-coding-standards' -Detail 'Every confirmed code-organization/style comment is promoted globally or by technology after implementation and clean review; business/domain/API behavior remains repository-scoped'

$guardTestRoot = Join-Path $OutputRoot 'execution-guard'
if (Test-Path -LiteralPath $guardTestRoot) { Remove-Item -LiteralPath $guardTestRoot -Recurse -Force }
New-Item -ItemType Directory -Path $guardTestRoot -Force | Out-Null
$guardTest = & (Join-Path $root 'scripts\Invoke-GuardedCodex.ps1') -FilePath 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'tests\fixtures\Emit-RepeatedCodexFailures.ps1'),'reasoning_effort=medium') -Prompt '' -WorkingDirectory $root -LogPath (Join-Path $guardTestRoot 'events.jsonl') -GuardArtifactPath (Join-Path $guardTestRoot 'guard.json') -MaxIdenticalFailures 3 -MaxRunMinutes 1 -PollMilliseconds 100
$guardTemporaryFiles = @(Get-ChildItem -LiteralPath $guardTestRoot -File | Where-Object Name -Match '\.(stdin\.txt|stdout\.tmp)$')
if (-not [bool]$guardTest.guardTriggered -or [int]$guardTest.identicalFailureCount -ne 3 -or [int]$guardTest.exitCode -ne 1 -or [string]$guardTest.reason -notmatch 'retry limit' -or -not (Test-Path -LiteralPath (Join-Path $guardTestRoot 'guard.json') -PathType Leaf) -or $guardTemporaryFiles.Count -ne 0) { throw 'Execution guard did not stop the deterministic repeated-failure fixture after exactly three attempts and clean up redirected temporary files.' }
Add-Check -Name 'execution-retry-guard' -Detail 'Three identical failures stop execution, produce a guard artifact, and release redirected temporary files'
$capacityRunner = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-CapacityAwareCodex.ps1') -Raw -Encoding UTF8
if ($workflowRunner -notmatch 'Invoke-CapacityAwareCodex.ps1' -or $capacityRunner -notmatch 'model-capacity' -or $capacityRunner -notmatch 'MaxCapacityFallbackAttempts' -or -not [bool]$config.modelRouting.capacityFallback.enabled -or [int]$config.modelRouting.capacityFallback.maxAttempts -ne 1) { throw 'Capacity fallback is not restricted to one exact model-capacity retry.' }
if ($healthRecoverySchema -match '"allOf"' -or $healthRecoverySchema -match '"if"' -or $healthRecoverySchema -notmatch '"humanIntervention"') { throw 'Health recovery schema is not Structured Outputs compatible.' }
Add-Check -Name 'capacity-fallback-and-health-schema' -Detail 'One capacity-only retry uses the configured fallback tier; Health Recovery schema contains no unsupported conditionals'

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

$setupPromptPath = Join-Path $root 'SETUP_WITH_LLM.md'
if (-not (Test-Path -LiteralPath $setupPromptPath -PathType Leaf)) { throw 'The interactive LLM setup prompt is missing.' }
$setupPrompt = Get-Content -LiteralPath $setupPromptPath -Raw -Encoding UTF8
foreach ($requiredSetupContract in @('Mandatory reading','Interview protocol','Repositories: for every managed repository','Never ask the developer to paste passwords','az devops login','redacted summary','Start-DevelopmentWorkflow.ps1 -PrepareOnly','separate confirmation before running `scripts/Install-AgentEcosystem.ps1`')) {
    if ($setupPrompt -notmatch [regex]::Escape($requiredSetupContract)) { throw "The interactive LLM setup prompt is missing contract text: $requiredSetupContract" }
}
Add-Check -Name 'llm-guided-installation' -Detail 'The branch contains a provider-aware interactive setup interview with secret handling, preview, validation, prepare-only smoke, and separate installation approval'

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

$knowledgeImportFixtureRoot = Join-Path $OutputRoot 'knowledge-import-conflict'
$knowledgeImportSourceRoot = Join-Path $knowledgeImportFixtureRoot 'source'
$knowledgeImportManagedRoot = Join-Path $knowledgeImportFixtureRoot 'managed'
$knowledgeImportConfigPath = Join-Path $knowledgeImportFixtureRoot 'agents.json'
New-Item -ItemType Directory -Path $knowledgeImportSourceRoot,$knowledgeImportManagedRoot -Force | Out-Null
Write-Utf8NoBom -Path (Join-Path $knowledgeImportSourceRoot 'seed.md') -Content ('seed version' + [Environment]::NewLine)
$knowledgeImportConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$knowledgeImportConfig.knowledge.seedSources = @([pscustomobject][ordered]@{ id='knowledge-import-test'; path=$knowledgeImportSourceRoot; mode='read-only-import'; includeExtensions=@('.md') })
$knowledgeImportConfig.knowledge.managedRoot = $knowledgeImportManagedRoot
Write-Utf8NoBom -Path $knowledgeImportConfigPath -Content (($knowledgeImportConfig | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

$null = & (Join-Path $root 'scripts\Import-InitialKnowledge.ps1') -SourceId 'knowledge-import-test' -ConfigPath $knowledgeImportConfigPath -CodexHome $CodexHome
$knowledgeImportTargetPath = Join-Path $knowledgeImportManagedRoot 'seed.md'
Write-Utf8NoBom -Path $knowledgeImportTargetPath -Content ('managed version' + [Environment]::NewLine)
$secondKnowledgeImport = & (Join-Path $root 'scripts\Import-InitialKnowledge.ps1') -SourceId 'knowledge-import-test' -ConfigPath $knowledgeImportConfigPath -CodexHome $CodexHome
$thirdKnowledgeImport = & (Join-Path $root 'scripts\Import-InitialKnowledge.ps1') -SourceId 'knowledge-import-test' -ConfigPath $knowledgeImportConfigPath -CodexHome $CodexHome
$preservedKnowledge = Get-Content -LiteralPath $knowledgeImportTargetPath -Raw -Encoding UTF8
if ([int]$secondKnowledgeImport.ConflictCount -ne 1 -or [int]$thirdKnowledgeImport.ConflictCount -ne 1 -or [bool]$thirdKnowledgeImport.ManifestUpdated -or $preservedKnowledge -ne ('managed version' + [Environment]::NewLine)) {
    throw 'Repeated knowledge import did not preserve an existing managed conflict idempotently.'
}
Add-Check -Name 'knowledge-import-conflict-preservation' -Detail 'Repeated imports preserve managed changes and retain skipped-managed-change without manifest churn'

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
