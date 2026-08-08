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
foreach ($marker in @('/api/tasks','/agents/','/artifacts/','/comments','/api/health-checks/run','/health-recovery/elevated','/workflow/elevated','/workflow/stop','/resume','already-repaired','Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Add-TaskComment.ps1','Invoke-EcosystemHealthCheck.ps1','maximumPreviewBytes')) {
    if ($dashboardServer -notmatch [regex]::Escape($marker)) { throw "Dashboard server is missing task-monitor contract marker: $marker" }
}
if ($dashboardServer -notmatch 'Start-ScriptRunspace' -or $dashboardServer -notmatch 'in-process-runspace') { throw 'Elevated workflow must avoid the nested PowerShell process through a tracked in-process runspace.' }
if ($dashboardServer -notmatch 'tasks=@\(\$result\.Tasks\)') { throw 'Dashboard API must expose the task collection as lower-camel-case tasks.' }
foreach ($controlId in @('repositoryOptions','repositorySummary','taskList','taskDetail','inputRequiredPanel','openQuestions','taskInterventionPanel','taskComment','taskQuestionTarget','sendTaskComment','resumeTask','stopWorkflow','resumeElevatedWorkflow','executionPolicyNotice','runHealthCheck','artifactViewer','artifactContent','closeArtifactViewer','agentLogPanel','agentLogTitle','agentLogMeta','agentLogEntries','closeAgentLog','agentOutcomePanel','agentOutcomeTitle','agentOutcomeMeta','agentOutcomeSummary','agentOutcomeArtifacts','agentOutcomeArtifactMeta','agentOutcomeContent','closeAgentOutcome','agentComment','agentActionStatus','sendAgentComment','restartAgentWithComment','approveElevatedRecovery')) {
    if ($dashboardHtml -notmatch ('id=["'']' + [regex]::Escape($controlId) + '["'']')) { throw "Dashboard UI is missing control: $controlId" }
    if ($dashboardClient -notmatch [regex]::Escape("#$controlId")) { throw "Dashboard client does not use control: $controlId" }
}
foreach ($scriptName in @('Get-AgentTasks.ps1','Get-AgentActivity.ps1','Get-AgentResumePlan.ps1','Get-AgentCommentBatch.ps1','Acknowledge-AgentCommentBatch.ps1','Write-AgentActivity.ps1','Add-TaskComment.ps1','Open-AgentQuestion.ps1','Set-AgentTaskStatus.ps1','Save-AgentCheckpoint.ps1','Publish-AgentOutcome.ps1')) {
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
Add-Check -Name 'configuration-semantics' -Detail "mode=$($config.operation.mode); repositories=$(@($config.repositories).Count); agents=$(@($config.agents).Count)"

$knowledgePrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\knowledge-keeper.md') -Raw -Encoding UTF8
$taskProtocol = Get-Content -LiteralPath (Join-Path $root 'prompts\common\task-protocol.md') -Raw -Encoding UTF8
$healthPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\health-check.md') -Raw -Encoding UTF8
$resumeScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Get-AgentResumePlan.ps1') -Raw -Encoding UTF8
$healthRecoveryScript = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentHealthRecovery.ps1') -Raw -Encoding UTF8
if ($knowledgePrompt -notmatch 'Never cyclically poll' -or $knowledgePrompt -notmatch 'explicit agent knowledge or skill requests') { throw 'Knowledge Keeper is not pull-based or still permits subagent polling.' }
if ($taskProtocol -notmatch 'Publish-AgentOutcome.ps1' -or $taskProtocol -notmatch 'agent-checkpoints' -or $taskProtocol -notmatch 'autonomous bounded work blocks' -or $taskProtocol -notmatch 'Get-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'Acknowledge-AgentCommentBatch.ps1' -or $taskProtocol -notmatch 'same agent invocation') { throw 'Private checkpoint, autonomous work-block, successful outcome, or end-of-block comment contract is missing.' }
if ($dashboardHtml -notmatch 'finishing its current work block' -or $dashboardClient -notmatch 'no restart is needed') { throw 'Dashboard does not explain automatic end-of-block comment consumption.' }
if ($healthPrompt -notmatch 'health-diagnostic-context.json' -or $healthRecoveryScript -notmatch 'Get-BoundedTextTail' -or $healthRecoveryScript -notmatch 'workflowLogTailLines') { throw 'Health Check bounded diagnostic context is incomplete.' }
if ($resumeScript -notmatch 'ChangedArtifactNames' -or $resumeScript -notmatch 'resume-artifact-index.json' -or $resumeScript -notmatch 'shareableArtifacts' -or $resumeScript -notmatch "-ne 'completed'") { throw 'Resume artifact fingerprinting or completed-outcome filtering is incomplete.' }
$knowledgeAgent = @($config.agents | Where-Object id -eq 'knowledge_keeper') | Select-Object -First 1
if (@($knowledgeAgent.requiredArtifacts) -notcontains 'task-summary.json' -or -not (Test-Path -LiteralPath (Join-Path $root 'config\schemas\task-summary.schema.json'))) { throw 'Final per-task summary contract is incomplete.' }
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
foreach ($healthScript in @('Invoke-EcosystemHealthCheck.ps1','Write-AgentFailure.ps1','Start-AgentHealthRecovery.ps1','Invoke-GuardedCodex.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$healthScript") -PathType Leaf)) { throw "Health recovery script is missing: $healthScript" }
}
Add-Check -Name 'health-recovery-contract' -Detail "automatic=$($config.health.automaticRecovery.enabled); attempts=$($config.health.automaticRecovery.maxAttemptsPerFailureSignature); sandbox=workspace-write; elevated=approval-gated; productWrites=false; externalWrites=false"

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
