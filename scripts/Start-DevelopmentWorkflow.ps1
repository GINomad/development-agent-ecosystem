[CmdletBinding()]
param(
    [ValidateSet('manual','automate')][string] $Mode,
    [string] $TaskSelector,
    [string] $TaskId,
    [string] $RepositoryId,
    [string[]] $RepositoryIds = @(),
    [string] $Workspace,
    [string] $UserInstruction,
    [switch] $Resume,
    [ValidatePattern('^[a-z][a-z0-9_]*$')][string] $TargetAgentId,
    [switch] $ElevatedApproved,
    [switch] $HealthRecoveryRetry,
    [switch] $ContinueChain,
    [switch] $SkipChainContinuation,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ($TargetAgentId -and -not @($config.agents | Where-Object { [string]$_.id -eq $TargetAgentId }).Count) { throw "Unknown target agent '$TargetAgentId'." }
$executionMode = if ($ElevatedApproved) { 'elevated-approved' } else { 'sandboxed' }
if ($ElevatedApproved) {
    if (-not [bool]$config.runtime.elevatedFallback.enabled -or -not [bool]$config.runtime.elevatedFallback.requiresDashboardApproval) { throw 'Elevated workflow execution is not enabled with an explicit approval gate.' }
    $workflowSandboxMode = [string]$config.runtime.elevatedFallback.sandboxMode
    $workflowApprovalPolicy = 'never'
}
else {
    $workflowSandboxMode = 'workspace-write'
    $workflowApprovalPolicy = [string]$config.runtime.approvalPolicy
}
if (-not $Mode) { $Mode = [string]$config.operation.mode }

if ($Mode -eq 'manual') {
    if (-not $TaskSelector) { throw 'Manual mode requires -TaskSelector (work item ID, URL, or a precise task description).' }
    if (-not $TaskId) {
        $candidate = ($TaskSelector -replace '^.*?([0-9]+).*$', '$1')
        $TaskId = if ($candidate -match '^[0-9]+$') { "task-$candidate" } else { 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    }
}
else {
    if (-not $TaskId) { $TaskId = 'automate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    if (-not $TaskSelector) { $TaskSelector = 'All enabled task sources assigned to the configured user.' }
}

$requestedRepositoryIds = [Collections.Generic.List[string]]::new()
foreach ($id in @($RepositoryIds) + @($RepositoryId)) {
    $value = [string]$id
    if ([string]::IsNullOrWhiteSpace($value) -or $requestedRepositoryIds.Contains($value)) { continue }
    $requestedRepositoryIds.Add($value)
}
if (-not $requestedRepositoryIds.Count) {
    $defaultRepository = @($config.repositories | Where-Object { $_.enabled }) | Select-Object -First 1
    if ($defaultRepository) { $requestedRepositoryIds.Add([string]$defaultRepository.id) }
}
$repositories = [Collections.Generic.List[object]]::new()
foreach ($id in $requestedRepositoryIds) {
    $repository = @($config.repositories | Where-Object { $_.id -eq $id -and $_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$id' was not found." }
    $repositories.Add($repository)
}
if (-not $repositories.Count) { throw 'At least one enabled repository is required.' }
$RepositoryIds = @($repositories | ForEach-Object { [string]$_.id })
$RepositoryId = $RepositoryIds[0]
if (-not $Workspace) { $Workspace = [string]$repositories[0].localWorkspace }
$workspacePaths = [Collections.Generic.List[string]]::new()
$workspacePaths.Add([IO.Path]::GetFullPath($Workspace))
for ($index = 1; $index -lt $repositories.Count; $index++) {
    $candidate = [IO.Path]::GetFullPath([string]$repositories[$index].localWorkspace)
    if (-not $workspacePaths.Contains($candidate)) { $workspacePaths.Add($candidate) }
}
foreach ($workspacePath in $workspacePaths) {
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) { throw "Workspace was not found: $workspacePath" }
    if (-not (Test-Path -LiteralPath (Join-Path $workspacePath '.git'))) { throw "Workspace is not a Git repository: $workspacePath" }
}

$knowledgeImport = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$syncParameters = @{ ConfigPath=$ConfigPath; CodexHome=$CodexHome; Install=$true }
if ($ElevatedApproved) { $syncParameters.IncludeHostCompatibilityProfile = $true }
$sync = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') @syncParameters
$task = & (Join-Path $PSScriptRoot 'New-AgentTask.ps1') -TaskId $TaskId -TaskSelector $TaskSelector -Mode $Mode -RepositoryIds $RepositoryIds -Resume:$Resume -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not $Resume -and -not [string]::IsNullOrWhiteSpace($UserInstruction)) {
    & (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') -TaskId $TaskId -Text $UserInstruction -Author user -TargetAgentId ([string]$config.workflow.orchestration.agentId) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
$workspaceLease = & (Join-Path $PSScriptRoot 'Switch-TaskWorkspace.ps1') -TaskId $TaskId -PrepareOnly:$PrepareOnly -ConfigPath $ConfigPath -CodexHome $CodexHome
if ([string]$workspaceLease.Status -in @('queued','restore-conflict')) {
    return [pscustomobject]@{ Mode=$Mode; TaskId=$TaskId; TaskRoot=$task.TaskRoot; RepositoryIds=@($RepositoryIds); WorkspaceLease=$workspaceLease; Status=[string]$workspaceLease.Status }
}
$agentProfileSuffix = if ($ElevatedApproved) { [string]$config.runtime.elevatedFallback.agentProfileSuffix } else { '' }
$orchestratorAgentName = 'development_workflow_orchestrator' + $agentProfileSuffix
$knowledgeAgentName = 'development_knowledge_keeper' + $agentProfileSuffix
$requirementsAgentName = 'development_requirements_analyst' + $agentProfileSuffix
$developerAgentName = 'development_implementer' + $agentProfileSuffix
$reviewerAgentName = 'development_reviewer' + $agentProfileSuffix
$pipelineAgentName = 'development_pipeline_monitor' + $agentProfileSuffix
$healthAgentName = 'development_health_check' + $agentProfileSuffix
$resumePlan = $null
$resumeScope = 'new-workflow'
if ($Resume) {
    $resumeParameters = @{ TaskId=$TaskId; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
    if ($TargetAgentId) { $resumeParameters.TargetAgentId = $TargetAgentId }
    $resumePlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') @resumeParameters
    if (-not [bool]$resumePlan.HasWork) { throw "Task '$TaskId' has no unfinished agents to resume." }
    $resumeScope = [string]$resumePlan.Mode
    Write-Utf8NoBom -Path (Join-Path $task.TaskRoot 'resume-plan.json') -Content (($resumePlan | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

$executedAgentId = if ($TargetAgentId) { $TargetAgentId } else { [string]$config.workflow.orchestration.agentId }
$activeAgent = @($config.agents | Where-Object { [string]$_.id -eq $executedAgentId }) | Select-Object -First 1
$contextPack = $null
if (-not $PrepareOnly) {
    $contextArtifactNames = if ($resumePlan) { @(@($resumePlan.ChangedArtifactNames) + @($resumePlan.UnchangedArtifactNames) | Select-Object -Unique) } else { @() }
    $contextPack = & (Join-Path $PSScriptRoot 'Update-AgentContextPack.ps1') -TaskId $TaskId -RecipientAgentId $executedAgentId -ArtifactNames $contextArtifactNames -ConfigPath $ConfigPath -CodexHome $CodexHome
}
$modelRouteParameters = @{
    TaskId = $TaskId
    AgentId = $executedAgentId
    TaskSelector = $TaskSelector
    UserInstruction = $UserInstruction
    RepositoryIds = @($RepositoryIds)
    ChangedArtifactNames = if ($resumePlan) { @($resumePlan.ChangedArtifactNames) } else { @() }
    HealthRecoveryRetry = [bool]$HealthRecoveryRetry
    NoPersist = [bool]$PrepareOnly
    ConfigPath = $ConfigPath
    CodexHome = $CodexHome
}
$modelRoute = & (Join-Path $PSScriptRoot 'Resolve-AgentModelRoute.ps1') @modelRouteParameters
$activeRolePrompt = [Collections.Generic.List[string]]::new()
foreach ($pathValue in @($activeAgent.promptPaths)) {
    $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $config -CodexHome $CodexHome
    $activeRolePrompt.Add((Get-Content -LiteralPath $path -Raw).Trim())
}
$roleDirectory = @($config.agents | Where-Object { [string]$_.id -ne [string]$config.workflow.orchestration.agentId } | ForEach-Object {
    $responsibilities = @($_.responsibilities | ForEach-Object { [string]$_ }) -join ' | '
    "$([string]$_.id): $([string]$_.description) Responsibilities: $responsibilities"
}) -join [Environment]::NewLine
$executionIdentity = if ($TargetAgentId) { "You are the '$TargetAgentId' role for this exact targeted run. Execute that role's work yourself in this Codex process; do not merely announce or simulate a handoff." } else { 'You are the primary workflow coordinator for the configured development agent ecosystem. Orchestrator owns intake classification and dispatch; Knowledge Keeper is an on-demand knowledge service and final knowledge publisher.' }
$targetExecutionContract = if ($TargetAgentId) { @"
Targeted execution contract:
- Perform the '$TargetAgentId' work directly under the role prompt below. The installed custom-agent name is a policy reference, not a background process that survives this `codex exec` run.
- Do not call collaboration spawn or wait, do not claim that another agent is active, and do not stop after merely setting '$TargetAgentId' to running.
- Before returning, leave '$TargetAgentId' in exactly one terminal status: completed after validated outcome publication, waiting after an explicit input gate, or failed with structured failure evidence. A running or pending status at host exit is an execution failure.
- Execute no other role. After a successful terminal outcome, return to the trusted PowerShell host, which alone decides automatic chain continuation.
"@ } else { @"
Coordinator execution contract:
- Execute Orchestrator work directly in this Codex process. Do not claim a delivery agent is running unless its separate targeted host run has actually started.
- Publish the Orchestrator outcome and return to the trusted PowerShell host; the host starts the selected role in a separate targeted invocation.
"@ }
$prompt = @"
$executionIdentity

Task ID: $TaskId
Mode: $Mode
Task selector: $TaskSelector
Task state: $($task.TaskRoot)
Validated context pack: $(if ($contextPack) { [string]$contextPack.ContextPath } else { 'prepare-only; not written' })
Ecosystem root: $(Get-EcosystemRoot)
Primary workspace: $([IO.Path]::GetFullPath($Workspace))
All target workspaces: $($workspacePaths -join '; ')
Repository config IDs: $($RepositoryIds -join ', ')
Additional user instruction: $UserInstruction
Execution mode: $executionMode ($workflowSandboxMode)
Model route: $($modelRoute.complexity) -> $($modelRoute.model) with $($modelRoute.reasoningEffort) reasoning (confidence $($modelRoute.confidence); decision $($modelRoute.decisionId))
Health recovery retry: $([bool]$HealthRecoveryRetry)
Resume scope: $resumeScope
Target agent: $(if ($TargetAgentId) { $TargetAgentId } else { 'none' })
Unfinished agents permitted in this run: $(if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) -join ', ' } else { 'all roles under normal gates' })
Agents preserved from the checkpoint: $(if ($resumePlan) { @($resumePlan.PreservedAgentIds) -join ', ' } else { 'none' })
Changed artifacts since the previous checkpoint: $(if ($resumePlan -and @($resumePlan.ChangedArtifactNames).Count) { @($resumePlan.ChangedArtifactNames) -join ', ' } else { 'none' })
Unchanged artifacts available through existing summaries: $(if ($resumePlan -and @($resumePlan.UnchangedArtifactNames).Count) { @($resumePlan.UnchangedArtifactNames) -join ', ' } else { 'none' })

Resume rules:
- The trusted workspace coordinator permits only one active task. Never switch branches or use Git stash directly for task scheduling. Before this invocation it selected this task's saved branch and restored its task-specific stash. If another task was active, this task would have remained queued.
- When a Developer creates or changes the task branch, the current branch becomes this task's branch at the next workspace suspension. Uncommitted tracked and untracked changes are stashed with a task/repository identity before switching away and restored with stash apply before the task resumes. The stash is dropped only after successful restoration.
- A workspace restore conflict is a human-input gate. Never reset, clean, discard, or silently resolve it.
- On a new workflow or a non-targeted checkpoint resume, dispatch $orchestratorAgentName first. It must classify the requested outcome, select the narrowest workflow.orchestration.executionModes entry, and route the task-created event and every pending comment addressed to orchestrator through Set-WorkflowInputRoute.ps1 with explicit -ExecutionMode before any newly selected role starts.
- On an explicit targeted-agent resume, execute that exact role directly in this process. Do not replace it, delegate it, or start another role in that targeted invocation.
- Orchestrator must use the freshly loaded role directory below, select the smallest sufficient target set, and use Requirements Analyst as the configured fallback when the evidence is actionable but ownership remains unclear.
- Routed workflow-input events are the only general comments a delivery agent consumes. Explicit agent comments and linked question answers remain direct.
- A checkpoint resume MUST dispatch only the listed unfinished agents. Do not rerun a completed agent, repeat its completed work, or regenerate its artifacts. Consume completed artifacts as immutable checkpoint input.
- A targeted-agent resume MUST execute only the exact target role and reach its terminal status before this process returns. No other role may be started, reset, or have its artifacts rewritten.
- A role skipped by the active Orchestrator execution policy is intentionally excluded and must not make the checkpoint unfinished. A later routing decision may select it again. Preserve running, completed, waiting, and failed roles when the policy changes.
- Each permitted agent chooses the largest coherent bounded work block that stays inside ready scope, its role, approval gates, and configured context limits. It may execute successive blocks in the same invocation.
- At the end of every work block, the active agent calls Get-AgentCommentBatch.ps1 once, applies all applicable comments as one batch, acknowledges the processed IDs once, and decides whether another block is necessary. No restart is needed while that agent is still running. A comment addressed to another agent remains pending for that agent.
- If a batched comment is wholly or partly outside the active agent's configured responsibilities, that agent calls Request-OrchestratorCommentRouting.ps1 once for the affected IDs instead of acting outside its authority. After the agent publishes a successful outcome, dispatch Orchestrator before the normal next role; after Orchestrator routes the remainder, dispatch its earliest eligible target automatically. Do not require a manual restart for this authority handoff.
- Reuse `context-pack.json` summaries for unchanged artifacts. Read only the listed changed artifacts plus a role's own private checkpoint; reopen an unchanged artifact only for a named evidence gap.

Live task control:
- The persistent ledger is $($task.TaskRoot)\task-ledger.jsonl.
- Read pending ledger comments once after each completed work block and once immediately before terminal outcome publication. Do not idle-wait or poll the ledger or subagents while a block is running.
- User comments may clarify, pause, or redirect in-scope work, but they do not bypass approval gates or authorize unrelated external writes.
- Update visible per-agent state with $(Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') before and after every handoff. Use running, waiting, completed, failed, or skipped based only on evidence.
- Write concise factual live entries with $(Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') before and after each material action, handoff, test batch, blocker, or recovery step. Never include credentials, tokens, secrets, or invented activity.
- When comments have been incorporated, record a user-comment-acknowledged event whose evidence contains the processed comment event IDs, then call Set-AgentTaskStatus.ps1 with -AcknowledgeComments.
- If any agent requires user input, call $(Join-Path $PSScriptRoot 'Open-AgentQuestion.ps1') with the task ID, agent ID, and exact question. It publishes the question and atomically sets the task to waiting_for_input and that agent to waiting. Do not invent an answer or report a blocking question only in prose.
- A dashboard answer is authoritative only when the ledger contains its question-resolved event. Reread the linked user-comment before resuming the held scope.
- Do not retry an identical failed execution more than $([int]$config.runtime.executionGuard.maxIdenticalFailures) times. On the third failure, stop immediately, persist the failure evidence, and hand it to development_health_check. Do not enter a wait loop after the retry limit.
- A Health Check targeted retry is the single post-repair attempt for its failure signature. If that retry fails, persist the new failure and stop; do not dispatch Health Check recursively from the retry.
- In elevated-approved mode, the user approved an OS-sandbox bypass for this task session. Every role may use the available local tools despite error 1260, but this does not authorize external writes, requirement assumptions, unapproved review fixes, or work outside the target workspace and ecosystem root.

Configured role directory (authoritative for routing):
$roleDirectory

$targetExecutionContract

The trusted host follows only the latest persisted Orchestrator agentSequence. Full delivery remains Requirements Analyst -> Developer -> Reviewer -> Pipeline Monitor -> Knowledge Keeper, while research-only and other narrow modes stop after their configured roles. In host-compatible mode the current invocation uses the approved host-compatible sandbox. Dispatch Health Check only through the trusted host when an agent fails, a required artifact is missing or invalid, a workflow is stuck, or a dashboard/runtime contract fails. In automate mode, enumerate assigned tasks but process no more than $($config.operation.automate.maxTasksPerRun) tasks in this run. Do not implement held scope. Do not apply proposed review findings without explicit human decisions. Do not perform external writes without explicit authorization.

$($activeRolePrompt -join ([Environment]::NewLine + [Environment]::NewLine))
"@

$result = [pscustomobject]@{
    Mode = $Mode
    TaskId = $TaskId
    TaskRoot = $task.TaskRoot
    Workspace = [IO.Path]::GetFullPath($Workspace)
    Workspaces = @($workspacePaths)
    RepositoryIds = @($RepositoryIds)
    ManagedKnowledgeRoot = $knowledgeImport.ManagedRoot
    AgentFiles = @($sync.AgentFiles)
    Prompt = $prompt
    ResumeScope = $resumeScope
    TargetAgentId = $TargetAgentId
    ModelRoute = $modelRoute
    WorkspaceLease = $workspaceLease
    UnfinishedAgentIds = if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) } else { @() }
}
if ($PrepareOnly) { return $result }

$statusScript = Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1'
$startMessage = if ($TargetAgentId) { "Targeted restart started for agent '$TargetAgentId'." } elseif ($Resume) { "Checkpoint resume started through Orchestrator for unfinished agents: $(@($resumePlan.UnfinishedAgentIds) -join ', ')." } else { 'Workflow started. Orchestrator is classifying task intake.' }
$startMessage += " Model route: $($modelRoute.complexity), $($modelRoute.model), reasoning $($modelRoute.reasoningEffort)."
$startStage = if ($TargetAgentId) { $TargetAgentId } else { 'orchestrator' }
& $statusScript -TaskId $TaskId -Status running -Stage $startStage -Message $startMessage -ProcessId $PID -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$updateOrchestratorStatus = -not $TargetAgentId -or $TargetAgentId -eq 'orchestrator'
& $statusScript -TaskId $TaskId -AgentId $executedAgentId -AgentStatus running -Stage $executedAgentId -Message $startMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$codexLogPath = Join-Path $task.TaskRoot 'workflow-codex.jsonl'
$finalResponsePath = Join-Path $task.TaskRoot 'workflow-final-response.md'
$guardArtifactPath = Join-Path $task.TaskRoot 'workflow-execution-guard.json'
$arguments = [Collections.Generic.List[string]]::new()
foreach ($argument in @('-a', $workflowApprovalPolicy, '--model', [string]$modelRoute.model, '--config', ('model_reasoning_effort="' + [string]$modelRoute.reasoningEffort + '"'), 'exec', '-C', [IO.Path]::GetFullPath($Workspace))) { $arguments.Add([string]$argument) }
$additionalDirectories = @($workspacePaths | Select-Object -Skip 1) + @((Get-EcosystemRoot))
foreach ($directory in $additionalDirectories) {
    $resolvedDirectory = [IO.Path]::GetFullPath([string]$directory)
    if ($resolvedDirectory -eq [IO.Path]::GetFullPath($Workspace)) { continue }
    $arguments.Add('--add-dir')
    $arguments.Add($resolvedDirectory)
}
foreach ($argument in @('-s', $workflowSandboxMode, '--json', '-o', $finalResponsePath, '-')) { $arguments.Add([string]$argument) }
$workflowStartedAtUtc = [DateTime]::UtcNow
try {
    $runHeader = [ordered]@{ type='ecosystem-workflow-run'; taskId=$TaskId; startedAtUtc=$workflowStartedAtUtc.ToString('o'); runner='codex exec'; modelRouteDecisionId=[string]$modelRoute.decisionId; model=[string]$modelRoute.model; reasoningEffort=[string]$modelRoute.reasoningEffort } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($codexLogPath, $runHeader + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $codexCliPath = Resolve-CodexCliPath
    if (-not $codexCliPath) { throw 'Codex CLI was not found.' }
    $guardResult = & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') -FilePath $codexCliPath -Arguments @($arguments) -Prompt $prompt -WorkingDirectory ([IO.Path]::GetFullPath($Workspace)) -LogPath $codexLogPath -GuardArtifactPath $guardArtifactPath -MaxIdenticalFailures ([int]$config.runtime.executionGuard.maxIdenticalFailures) -MaxRunMinutes ([int]$config.runtime.executionGuard.maxRunMinutes) -PollMilliseconds ([int]$config.runtime.executionGuard.pollMilliseconds)
    $codexExitCode = [int]$guardResult.exitCode
    if ([bool]$guardResult.guardTriggered) { throw [string]$guardResult.reason }
    if ($codexExitCode -ne 0) { throw "Codex exited with code $codexExitCode. See $codexLogPath" }
    & (Join-Path $PSScriptRoot 'Assert-TargetAgentTerminalState.ps1') -TaskId $TaskId -AgentId $executedAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentStatus = [string]$currentTask.status
    if ($TargetAgentId) {
        & (Join-Path $PSScriptRoot 'Resolve-StaleAgentQuestions.ps1') -TaskId $TaskId -AgentId $TargetAgentId -RestartedAtUtc $workflowStartedAtUtc -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    if ($TargetAgentId -eq 'health_check' -and -not $HealthRecoveryRetry -and [bool]$config.health.automaticRecovery.enabled) {
        $diagnosisPath = Join-Path $task.TaskRoot 'health-check-result.json'
        $diagnosis = $null
        if (Test-Path -LiteralPath $diagnosisPath -PathType Leaf) {
            $diagnosis = Get-Content -LiteralPath $diagnosisPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        $healthStatus = [string]$currentTask.agentStatuses.health_check.status
        $completedEcosystemRecovery = $healthStatus -eq 'completed' -and $diagnosis -and
            $diagnosis.PSObject.Properties['repairOwner'] -and [string]$diagnosis.repairOwner -eq 'ecosystem_recovery' -and
            (-not $diagnosis.PSObject.Properties['requiresUserInput'] -or -not [bool]$diagnosis.requiresUserInput)
        $healthRecoveryEligible = $healthStatus -eq 'waiting' -or $completedEcosystemRecovery
        $failurePath = $null
        if ($healthRecoveryEligible -and $completedEcosystemRecovery) {
            foreach ($candidate in @(Get-ChildItem -LiteralPath $task.TaskRoot -Filter 'agent-failure-*.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
                try { $candidateFailure = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                if ([string]$candidateFailure.stage -eq 'health_diagnosis_recovery' -and @($candidateFailure.evidence) -contains $diagnosisPath) {
                    $failurePath = $candidate.FullName
                    break
                }
            }
            if (-not $failurePath) {
                $affectedAgentId = if ($diagnosis.PSObject.Properties['affectedAgent']) { [string]$diagnosis.affectedAgent } else { '' }
                $allowedTargets = @($config.health.automaticRecovery.targetedResume.allowedAgentIds | ForEach-Object { [string]$_ })
                if ($affectedAgentId -notin $allowedTargets) {
                    $affectedAgentId = if ('orchestrator' -in $allowedTargets) { 'orchestrator' } else { $allowedTargets | Select-Object -First 1 }
                }
                if ([string]::IsNullOrWhiteSpace($affectedAgentId)) { throw 'Completed Health Check requested ecosystem recovery without an allowed affected agent.' }
                $failureResult = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId $affectedAgentId -Stage health_diagnosis_recovery -Summary ([string]$diagnosis.summary) -Diagnostic ([string]$diagnosis.rootCause) -Evidence @($diagnosisPath, "health-diagnosis-signature:$([string]$diagnosis.failureSignature)") -ConfigPath $ConfigPath -CodexHome $CodexHome
                $failurePath = [string]$failureResult.FailurePath
            }
        }
        elseif ($healthRecoveryEligible) {
            foreach ($candidate in @(Get-ChildItem -LiteralPath $task.TaskRoot -Filter 'agent-failure-*.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
                try { $candidateFailure = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
                if ([string]$candidateFailure.agentId -ne 'health_check') { $failurePath = $candidate.FullName; break }
            }
        }
        if ($healthRecoveryEligible -and $failurePath -and $diagnosis) {
            & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level progress -Stage health_recovery_handoff -Summary 'Health Check completed diagnosis and handed the bounded correction to automatic recovery.' -Details "Failure: $failurePath; diagnosis: $diagnosisPath" -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $recoveryParameters = @{ TaskId=$TaskId; FailurePath=$failurePath; DiagnosisPath=$diagnosisPath; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved) { $recoveryParameters.ElevatedApproved = $true }
            $postDiagnosisRecovery = & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') @recoveryParameters
            if ($postDiagnosisRecovery.PSObject.Properties['TargetedResume'] -and $postDiagnosisRecovery.TargetedResume) { return $postDiagnosisRecovery.TargetedResume }
            if ([string]$postDiagnosisRecovery.Status -in @('repaired','already-repaired')) { return $postDiagnosisRecovery }
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $currentStatus = [string]$currentTask.status
        }
    }
    if ($Resume -and -not $TargetAgentId -and $currentStatus -notin @('failed','waiting_for_input','held','review_pending')) {
        $remainingPlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $TaskId -PreserveArtifactIndex -ConfigPath $ConfigPath -CodexHome $CodexHome
        if ([bool]$remainingPlan.HasWork) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage checkpoint_incomplete -Message "Checkpoint run ended with unfinished agents: $(@($remainingPlan.UnfinishedAgentIds) -join ', ')." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    if ($TargetAgentId -and $currentStatus -notin @('failed','waiting_for_input','held','review_pending')) {
        $closureComplete = $TargetAgentId -eq 'knowledge_keeper' -and $currentTask.PSObject.Properties['closure'] -and [string]$currentTask.closure.status -eq 'knowledge-update-pending' -and [string]$currentTask.agentStatuses.knowledge_keeper.status -eq 'completed'
        $preservePipelineNonSuccess = $false
        $targetedPipelinePath = Join-Path $task.TaskRoot 'pipeline-result.json'
        if ($TargetAgentId -eq 'pipeline_monitor' -and (Test-Path -LiteralPath $targetedPipelinePath -PathType Leaf)) {
            $targetedPipelineResult = Get-Content -LiteralPath $targetedPipelinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $preservePipelineNonSuccess = [string]$targetedPipelineResult.overallResult -ne 'succeeded'
        }
        $preserveAwaitingPullRequest = $currentStatus -eq 'interrupted' -and $currentTask.PSObject.Properties['currentStage'] -and [string]$currentTask.currentStage -eq 'awaiting_pull_request'
        if ($closureComplete) {
            $completedAtUtc = [DateTime]::UtcNow.ToString('o')
            $currentTask.closure.status = 'completed'
            $currentTask.closure.completedAtUtc = $completedAtUtc
            Write-Utf8NoBom -Path (Join-Path $task.TaskRoot 'task.json') -Content (($currentTask | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
            $closureKind = [string]$currentTask.closure.kind
            & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor knowledge_keeper -Type task-closed -Summary "Task closure '$closureKind' completed after the required knowledge update. Reason: $([string]$currentTask.closure.reason)" -Artifact (Join-Path $task.TaskRoot 'task-summary.json') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            & $statusScript -TaskId $TaskId -Status completed -Stage $(if ($closureKind -eq 'manual') { 'manually_closed' } else { 'pr_completed' }) -Message 'Task closure completed. Knowledge and the final task summary were updated.' -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'completed'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (-not $closureComplete -and -not $preserveAwaitingPullRequest -and -not $preservePipelineNonSuccess) {
        $remainingPlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $TaskId -PreserveArtifactIndex -ConfigPath $ConfigPath -CodexHome $CodexHome
        if ([bool]$remainingPlan.HasWork) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage targeted_agent_completed -Message "Targeted restart for '$TargetAgentId' finished. Remaining agents: $(@($remainingPlan.UnfinishedAgentIds) -join ', ')." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
        }
        else {
            & $statusScript -TaskId $TaskId -Status completed -Stage completed -Message "Targeted restart for '$TargetAgentId' finished and no unfinished agents remain." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'completed'
        }
        $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        elseif ($preserveAwaitingPullRequest) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage awaiting_pull_request -Message "Targeted restart for '$TargetAgentId' finished; exact-commit delivery succeeded and the task is awaiting pull-request lifecycle evidence." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        elseif ($preservePipelineNonSuccess) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage pipeline_non_success -Message "Targeted Pipeline Monitor finished with '$([string]$targetedPipelineResult.overallResult)'; the task remains open for automatic remediation or Orchestrator routing." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    $currentStage = if ($currentTask.PSObject.Properties['currentStage']) { [string]$currentTask.currentStage } else { $currentStatus }
    if ($currentStatus -in @('waiting_for_input','held')) {
        if ($updateOrchestratorStatus) {
            & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus waiting -Stage $currentStage -Message 'The orchestration run stopped at an explicit user-input gate.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    elseif ($currentStatus -eq 'review_pending') {
        if ($updateOrchestratorStatus) {
            & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus completed -Stage review_pending -Message 'Orchestration is waiting for human review decisions.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    elseif ($currentStatus -eq 'interrupted') {
        if ($updateOrchestratorStatus) {
            & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus completed -Stage checkpoint_incomplete -Message 'Orchestrator completed coordination; one or more routed agents remain unfinished.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    elseif ($currentStatus -notin @('failed','interrupted','completed')) {
        if ($updateOrchestratorStatus) {
            & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus completed -Stage completed -Message 'Orchestrator completed intake routing and workflow coordination.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        & $statusScript -TaskId $TaskId -Status completed -Stage completed -Message 'Workflow completed. Review task artifacts for the final outcome.' -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    if ($currentStatus -notin @('created','queued','running','failed')) {
        try { & (Join-Path $PSScriptRoot 'Resolve-RecoveredControlPlaneStatuses.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Control-plane status reconciliation failed: $($_.Exception.Message)" }
    }
    if (-not $SkipChainContinuation -and [bool]$config.workflow.automaticContinuation.enabled) {
        $chainTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manualClosure = $chainTask.PSObject.Properties['closure'] -and [string]$chainTask.closure.kind -eq 'manual'
        if (-not $manualClosure -and [string]$chainTask.agentStatuses.$executedAgentId.status -eq 'completed') {
            & (Join-Path $PSScriptRoot 'Continue-AgentChain.ps1') -TaskId $TaskId -CompletedAgentId $executedAgentId -ElevatedApproved:$ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    if (-not $SkipChainContinuation) {
        try { & (Join-Path $PSScriptRoot 'Start-NextQueuedTask.ps1') -CompletedTaskId $TaskId -ElevatedApproved:$ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Queued-task continuation failed: $($_.Exception.Message)" }
    }
}
catch {
    $failureMessage = $_.Exception.Message
    $failureAgentId = if ($TargetAgentId) { $TargetAgentId } else { 'orchestrator' }
    & $statusScript -TaskId $TaskId -AgentId $failureAgentId -AgentStatus failed -Stage failed -Message $failureMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & $statusScript -TaskId $TaskId -Status failed -Stage failed -Message $failureMessage -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $failureEvidence = @($codexLogPath, $finalResponsePath, $guardArtifactPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $lastDiagnostic = if ((Get-Variable -Name guardResult -ErrorAction SilentlyContinue) -and [bool]$guardResult.guardTriggered) { [string]$guardResult.failureDetail } elseif (Test-Path -LiteralPath $codexLogPath -PathType Leaf) { (Get-Content -LiteralPath $codexLogPath -Tail 1 -Encoding UTF8 | Out-String).Trim() } else { $failureMessage }
    $failureExitCode = if (Get-Variable -Name codexExitCode -ErrorAction SilentlyContinue) { [Nullable[int]]$codexExitCode } else { $null }
    $failureHandoff = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId $failureAgentId -Stage failed -Summary $failureMessage -ExitCode $failureExitCode -Diagnostic $lastDiagnostic -Evidence $failureEvidence -ConfigPath $ConfigPath -CodexHome $CodexHome
    $hostCompatibilityReady = $false
    $automaticTargetedResume = $null
    if (-not $HealthRecoveryRetry -and [bool]$config.health.enabled -and [bool]$config.health.checkOnWorkflowFailure) {
        try {
            $healthCheckResult = & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $TaskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome
            $postHealthTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $hostCompatibilityReady = [string]$postHealthTask.currentStage -eq 'os_policy_compatibility_ready'
            if ($hostCompatibilityReady -and [bool]$config.health.automaticRecovery.targetedResume.enabled) {
                $taskHealthEvidencePath = Join-Path $task.TaskRoot 'health-check-result.json'
                if (Test-Path -LiteralPath $taskHealthEvidencePath -PathType Leaf) {
                    $targetedParameters = @{
                        TaskId = $TaskId
                        FailurePath = [string]$failureHandoff.FailurePath
                        RecoveryEvidencePath = $taskHealthEvidencePath
                        ConfigPath = $ConfigPath
                        CodexHome = $CodexHome
                    }
                    if ($ElevatedApproved) { $targetedParameters.ElevatedApproved = $true }
                    $automaticTargetedResume = & (Join-Path $PSScriptRoot 'Start-HealthTargetedResume.ps1') @targetedParameters
                }
            }
        }
        catch { Write-Warning "Health check also failed: $($_.Exception.Message)" }
    }
    if (-not $HealthRecoveryRetry -and [bool]$config.health.automaticRecovery.enabled -and -not $hostCompatibilityReady) {
        try {
            $healthRecoveryResult = & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $TaskId -FailurePath $failureHandoff.FailurePath -ConfigPath $ConfigPath -CodexHome $CodexHome
            if ($healthRecoveryResult.PSObject.Properties['TargetedResume']) { $automaticTargetedResume = $healthRecoveryResult.TargetedResume }
        }
        catch { Write-Warning "Automatic health recovery failed: $($_.Exception.Message)" }
    }
    if ($automaticTargetedResume -and [string]$automaticTargetedResume.Status -in @('completed','waiting','interrupted')) {
        if (-not $SkipChainContinuation) {
            try { & (Join-Path $PSScriptRoot 'Start-NextQueuedTask.ps1') -CompletedTaskId $TaskId -ElevatedApproved:$ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
            catch { Write-Warning "Queued-task continuation failed: $($_.Exception.Message)" }
        }
        return $automaticTargetedResume
    }
    if (-not $SkipChainContinuation) {
        try { & (Join-Path $PSScriptRoot 'Start-NextQueuedTask.ps1') -CompletedTaskId $TaskId -ElevatedApproved:$ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Queued-task continuation failed: $($_.Exception.Message)" }
    }
    throw
}
