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
    [ValidateSet('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor','health_check')][string] $TargetAgentId,
    [switch] $ElevatedApproved,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
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
$agentProfileSuffix = if ($ElevatedApproved) { [string]$config.runtime.elevatedFallback.agentProfileSuffix } else { '' }
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

$knowledgeAgent = @($config.agents | Where-Object { $_.id -eq 'knowledge_keeper' }) | Select-Object -First 1
$knowledgePrompt = [Collections.Generic.List[string]]::new()
foreach ($pathValue in @($knowledgeAgent.promptPaths)) {
    $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $config -CodexHome $CodexHome
    $knowledgePrompt.Add((Get-Content -LiteralPath $path -Raw).Trim())
}
$prompt = @"
You are the primary knowledge keeper for the configured development agent ecosystem.

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
Resume scope: $resumeScope
Target agent: $(if ($TargetAgentId) { $TargetAgentId } else { 'none' })
Unfinished agents permitted in this run: $(if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) -join ', ' } else { 'all roles under normal gates' })
Agents preserved from the checkpoint: $(if ($resumePlan) { @($resumePlan.PreservedAgentIds) -join ', ' } else { 'none' })
Changed artifacts since the previous checkpoint: $(if ($resumePlan -and @($resumePlan.ChangedArtifactNames).Count) { @($resumePlan.ChangedArtifactNames) -join ', ' } else { 'none' })
Unchanged artifacts available through existing summaries: $(if ($resumePlan -and @($resumePlan.UnchangedArtifactNames).Count) { @($resumePlan.UnchangedArtifactNames) -join ', ' } else { 'none' })

Resume rules:
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
- In elevated-approved mode, the user approved an OS-sandbox bypass for this task session. Every role may use the available local tools despite error 1260, but this does not authorize external writes, requirement assumptions, unapproved review fixes, or work outside the target workspace and ecosystem root.

Use the custom agents $requirementsAgentName, $developerAgentName, $reviewerAgentName, $pipelineAgentName, and $healthAgentName according to the configured gates. In host-compatible mode every selected subagent uses the current-user execution profile installed by Health Check; do not fall back to the standard sandboxed agent names. Dispatch $healthAgentName when an agent fails, a required artifact is missing or invalid, a workflow is stuck, or a dashboard/runtime contract fails. In automate mode, enumerate assigned tasks but process no more than $($config.operation.automate.maxTasksPerRun) tasks in this run. Do not implement held scope. Do not apply proposed review findings without explicit human decisions. Do not perform external writes without explicit authorization.

$($knowledgePrompt -join ([Environment]::NewLine + [Environment]::NewLine))
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
    UnfinishedAgentIds = if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) } else { @() }
}
if ($PrepareOnly) { return $result }

$statusScript = Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1'
$startMessage = if ($TargetAgentId) { "Targeted restart started for agent '$TargetAgentId'." } elseif ($Resume) { "Checkpoint resume started for unfinished agents: $(@($resumePlan.UnfinishedAgentIds) -join ', ')." } else { 'Workflow started. Knowledge Keeper is preparing task context.' }
& $statusScript -TaskId $TaskId -Status running -Stage knowledge_keeper -Message $startMessage -ProcessId $PID -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$updateKnowledgeKeeperStatus = -not $Resume -or $TargetAgentId -eq 'knowledge_keeper'
if ($updateKnowledgeKeeperStatus) {
    & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus running -Stage knowledge_keeper -Message $startMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
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
try {
    $runHeader = [ordered]@{ type='ecosystem-workflow-run'; taskId=$TaskId; startedAtUtc=[DateTime]::UtcNow.ToString('o'); runner='codex exec' } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($codexLogPath, $runHeader + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $codexCommand = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codexCommand) { throw 'Codex CLI was not found.' }
    $guardResult = & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') -FilePath $codexCommand.Source -Arguments @($arguments) -Prompt $prompt -WorkingDirectory ([IO.Path]::GetFullPath($Workspace)) -LogPath $codexLogPath -GuardArtifactPath $guardArtifactPath -MaxIdenticalFailures ([int]$config.runtime.executionGuard.maxIdenticalFailures) -MaxRunMinutes ([int]$config.runtime.executionGuard.maxRunMinutes) -PollMilliseconds ([int]$config.runtime.executionGuard.pollMilliseconds)
    $codexExitCode = [int]$guardResult.exitCode
    if ([bool]$guardResult.guardTriggered) { throw [string]$guardResult.reason }
    if ($codexExitCode -ne 0) { throw "Codex exited with code $codexExitCode. See $codexLogPath" }
    $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentStatus = [string]$currentTask.status
    if ($Resume -and -not $TargetAgentId -and $currentStatus -notin @('failed','waiting_for_input','held','review_pending')) {
        $remainingPlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
        if ([bool]$remainingPlan.HasWork) {
            & $statusScript -TaskId $TaskId -Status interrupted -Stage checkpoint_incomplete -Message "Checkpoint run ended with unfinished agents: $(@($remainingPlan.UnfinishedAgentIds) -join ', ')." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $currentStatus = 'interrupted'
            $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    if ($TargetAgentId -and $currentStatus -notin @('failed','waiting_for_input','held','review_pending')) {
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
    $currentStage = if ($currentTask.PSObject.Properties['currentStage']) { [string]$currentTask.currentStage } else { $currentStatus }
    if ($currentStatus -in @('waiting_for_input','held')) {
        if ($updateKnowledgeKeeperStatus) {
            & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus waiting -Stage $currentStage -Message 'The orchestration run stopped at an explicit user-input gate.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    elseif ($currentStatus -eq 'review_pending') {
        if ($updateKnowledgeKeeperStatus) {
            & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus completed -Stage review_pending -Message 'Orchestration is waiting for human review decisions.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    elseif ($currentStatus -notin @('failed','interrupted','completed')) {
        if ($updateKnowledgeKeeperStatus) {
            & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus completed -Stage completed -Message 'Knowledge Keeper completed the orchestration run.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        & $statusScript -TaskId $TaskId -Status completed -Stage completed -Message 'Workflow completed. Review task artifacts for the final outcome.' -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
}
catch {
    $failureMessage = $_.Exception.Message
    $failureAgentId = if ($TargetAgentId) { $TargetAgentId } else { 'knowledge_keeper' }
    & $statusScript -TaskId $TaskId -AgentId $failureAgentId -AgentStatus failed -Stage failed -Message $failureMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & $statusScript -TaskId $TaskId -Status failed -Stage failed -Message $failureMessage -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $failureEvidence = @($codexLogPath, $finalResponsePath, $guardArtifactPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $lastDiagnostic = if ((Get-Variable -Name guardResult -ErrorAction SilentlyContinue) -and [bool]$guardResult.guardTriggered) { [string]$guardResult.failureDetail } elseif (Test-Path -LiteralPath $codexLogPath -PathType Leaf) { (Get-Content -LiteralPath $codexLogPath -Tail 1 -Encoding UTF8 | Out-String).Trim() } else { $failureMessage }
    $failureExitCode = if (Get-Variable -Name codexExitCode -ErrorAction SilentlyContinue) { [Nullable[int]]$codexExitCode } else { $null }
    $failureHandoff = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId $failureAgentId -Stage failed -Summary $failureMessage -ExitCode $failureExitCode -Diagnostic $lastDiagnostic -Evidence $failureEvidence -ConfigPath $ConfigPath -CodexHome $CodexHome
    $hostCompatibilityReady = $false
    if ([bool]$config.health.enabled -and [bool]$config.health.checkOnWorkflowFailure) {
        try {
            & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $TaskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $postHealthTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $hostCompatibilityReady = [string]$postHealthTask.currentStage -eq 'os_policy_compatibility_ready'
        }
        catch { Write-Warning "Health check also failed: $($_.Exception.Message)" }
    }
    if ([bool]$config.health.automaticRecovery.enabled -and -not $hostCompatibilityReady) {
        try { & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $TaskId -FailurePath $failureHandoff.FailurePath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Automatic health recovery failed: $($_.Exception.Message)" }
    }
    throw
}
