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

$orchestratorAgent = @($config.agents | Where-Object { $_.id -eq [string]$config.workflow.orchestration.agentId }) | Select-Object -First 1
$orchestratorPrompt = [Collections.Generic.List[string]]::new()
foreach ($pathValue in @($orchestratorAgent.promptPaths)) {
    $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $config -CodexHome $CodexHome
    $orchestratorPrompt.Add((Get-Content -LiteralPath $path -Raw).Trim())
}
$roleDirectory = @($config.agents | Where-Object { [string]$_.id -ne [string]$config.workflow.orchestration.agentId } | ForEach-Object {
    $responsibilities = @($_.responsibilities | ForEach-Object { [string]$_ }) -join ' | '
    "$([string]$_.id): $([string]$_.description) Responsibilities: $responsibilities"
}) -join [Environment]::NewLine
$prompt = @"
You are the primary workflow coordinator for the configured development agent ecosystem. Orchestrator owns intake classification and dispatch; Knowledge Keeper is an on-demand knowledge service and final knowledge publisher.

Task ID: $TaskId
Mode: $Mode
Task selector: $TaskSelector
Task state: $($task.TaskRoot)
Ecosystem root: $(Get-EcosystemRoot)
Primary workspace: $([IO.Path]::GetFullPath($Workspace))
All target workspaces: $($workspacePaths -join '; ')
Repository config IDs: $($RepositoryIds -join ', ')
Additional user instruction: $UserInstruction
Execution mode: $executionMode ($workflowSandboxMode)
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
- On a new workflow or a non-targeted checkpoint resume, dispatch $orchestratorAgentName first. It must route the task-created event and every pending comment addressed to orchestrator through Set-WorkflowInputRoute.ps1 before any newly selected delivery role starts.
- On an explicit targeted-agent resume, preserve that explicit target. Orchestrator may classify already queued general inputs, but it must not replace the requested target or start a different role in that targeted invocation.
- Orchestrator must use the freshly loaded role directory below, select the smallest sufficient target set, and use Requirements Analyst as the configured fallback when the evidence is actionable but ownership remains unclear.
- Routed workflow-input events are the only general comments a delivery agent consumes. Explicit agent comments and linked question answers remain direct.
- A checkpoint resume MUST dispatch only the listed unfinished agents. Do not rerun a completed agent, repeat its completed work, or regenerate its artifacts. Consume completed artifacts as immutable checkpoint input.
- A targeted-agent resume MUST dispatch only the exact target agent. Knowledge Keeper may reconstruct context and persist the handoff, but no other role may be started, reset, or have its artifacts rewritten.
- A skipped role in an active checkpoint is unfinished and must be reconsidered when its prerequisite becomes available. When a role is conclusively not applicable, record evidence and mark it completed with a no-op result so future resumes do not repeat it.
- Each permitted agent chooses the largest coherent bounded work block that stays inside ready scope, its role, approval gates, and configured context limits. It may execute successive blocks in the same invocation.
- At the end of every work block, the active agent calls Get-AgentCommentBatch.ps1 once, applies all applicable comments as one batch, acknowledges the processed IDs once, and decides whether another block is necessary. No restart is needed while that agent is still running. A comment addressed to another agent remains pending for that agent.
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

Use the custom agents $orchestratorAgentName, $knowledgeAgentName, $requirementsAgentName, $developerAgentName, $reviewerAgentName, $pipelineAgentName, and $healthAgentName according to the configured gates. After Orchestrator persists a routing batch, it must publish its validated routing outcome and the coordinator dispatches the earliest eligible routed target. The existing Requirements Analyst -> Developer -> Reviewer -> Pipeline Monitor -> Knowledge Keeper continuation remains unchanged. In host-compatible mode every selected subagent uses the current-user execution profile installed by Health Check; do not fall back to the standard sandboxed agent names. Dispatch $healthAgentName when an agent fails, a required artifact is missing or invalid, a workflow is stuck, or a dashboard/runtime contract fails. In automate mode, enumerate assigned tasks but process no more than $($config.operation.automate.maxTasksPerRun) tasks in this run. Do not implement held scope. Do not apply proposed review findings without explicit human decisions. Do not perform external writes without explicit authorization.

$($orchestratorPrompt -join ([Environment]::NewLine + [Environment]::NewLine))
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
    WorkspaceLease = $workspaceLease
    UnfinishedAgentIds = if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) } else { @() }
}
if ($PrepareOnly) { return $result }

$statusScript = Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1'
$startMessage = if ($TargetAgentId) { "Targeted restart started for agent '$TargetAgentId'." } elseif ($Resume) { "Checkpoint resume started through Orchestrator for unfinished agents: $(@($resumePlan.UnfinishedAgentIds) -join ', ')." } else { 'Workflow started. Orchestrator is classifying task intake.' }
& $statusScript -TaskId $TaskId -Status running -Stage orchestrator -Message $startMessage -ProcessId $PID -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$updateOrchestratorStatus = -not $TargetAgentId -or $TargetAgentId -eq 'orchestrator'
if ($updateOrchestratorStatus) {
    & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus running -Stage orchestrator -Message $startMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

$codexLogPath = Join-Path $task.TaskRoot 'workflow-codex.jsonl'
$finalResponsePath = Join-Path $task.TaskRoot 'workflow-final-response.md'
$guardArtifactPath = Join-Path $task.TaskRoot 'workflow-execution-guard.json'
$arguments = [Collections.Generic.List[string]]::new()
foreach ($argument in @('-a', $workflowApprovalPolicy, 'exec', '-C', [IO.Path]::GetFullPath($Workspace))) { $arguments.Add([string]$argument) }
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
    $runHeader = [ordered]@{ type='ecosystem-workflow-run'; taskId=$TaskId; startedAtUtc=$workflowStartedAtUtc.ToString('o'); runner='codex exec' } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($codexLogPath, $runHeader + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $codexCommand = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codexCommand) { throw 'Codex CLI was not found.' }
    $guardResult = & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') -FilePath $codexCommand.Source -Arguments @($arguments) -Prompt $prompt -WorkingDirectory ([IO.Path]::GetFullPath($Workspace)) -LogPath $codexLogPath -GuardArtifactPath $guardArtifactPath -MaxIdenticalFailures ([int]$config.runtime.executionGuard.maxIdenticalFailures) -MaxRunMinutes ([int]$config.runtime.executionGuard.maxRunMinutes) -PollMilliseconds ([int]$config.runtime.executionGuard.pollMilliseconds)
    $codexExitCode = [int]$guardResult.exitCode
    if ([bool]$guardResult.guardTriggered) { throw [string]$guardResult.reason }
    if ($codexExitCode -ne 0) { throw "Codex exited with code $codexExitCode. See $codexLogPath" }
    $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentStatus = [string]$currentTask.status
    if ($TargetAgentId) {
        & (Join-Path $PSScriptRoot 'Resolve-StaleAgentQuestions.ps1') -TaskId $TaskId -AgentId $TargetAgentId -RestartedAtUtc $workflowStartedAtUtc -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    if ($TargetAgentId -eq 'health_check' -and -not $HealthRecoveryRetry -and [bool]$config.health.automaticRecovery.enabled -and [string]$currentTask.agentStatuses.health_check.status -eq 'waiting') {
        $diagnosisPath = Join-Path $task.TaskRoot 'health-check-result.json'
        $failurePath = $null
        foreach ($candidate in @(Get-ChildItem -LiteralPath $task.TaskRoot -Filter 'agent-failure-*.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
            try { $candidateFailure = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ([string]$candidateFailure.agentId -ne 'health_check') { $failurePath = $candidate.FullName; break }
        }
        if ($failurePath -and (Test-Path -LiteralPath $diagnosisPath -PathType Leaf)) {
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
        $remainingPlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
        if ([bool]$remainingPlan.HasWork) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage checkpoint_incomplete -Message "Checkpoint run ended with unfinished agents: $(@($remainingPlan.UnfinishedAgentIds) -join ', ')." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    if ($TargetAgentId -and $currentStatus -notin @('failed','waiting_for_input','held','review_pending')) {
        $closureComplete = $TargetAgentId -eq 'knowledge_keeper' -and $currentTask.PSObject.Properties['closure'] -and [string]$currentTask.closure.status -eq 'knowledge-update-pending' -and [string]$currentTask.agentStatuses.knowledge_keeper.status -eq 'completed'
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
        if (-not $closureComplete) {
        $remainingPlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
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
    elseif ($currentStatus -notin @('failed','interrupted','completed')) {
        if ($updateOrchestratorStatus) {
            & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus completed -Stage completed -Message 'Orchestrator completed intake routing and workflow coordination.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        & $statusScript -TaskId $TaskId -Status completed -Stage completed -Message 'Workflow completed. Review task artifacts for the final outcome.' -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    if ($TargetAgentId -and $ContinueChain -and -not $SkipChainContinuation -and $TargetAgentId -ne 'health_check') {
        $chainTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $manualClosure = $chainTask.PSObject.Properties['closure'] -and [string]$chainTask.closure.kind -eq 'manual'
        if (-not $manualClosure -and [string]$chainTask.agentStatuses.$TargetAgentId.status -eq 'completed') {
            & (Join-Path $PSScriptRoot 'Continue-AgentChain.ps1') -TaskId $TaskId -CompletedAgentId $TargetAgentId -ElevatedApproved:$ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
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
