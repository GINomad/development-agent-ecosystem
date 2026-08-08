[CmdletBinding()]
param(
    [ValidateSet('manual','automate')][string] $Mode,
    [string] $TaskSelector,
    [string] $TaskId,
    [string] $RepositoryId,
    [string] $Workspace,
    [string] $UserInstruction,
    [switch] $Resume,
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

if ($RepositoryId) {
    $repository = @($config.repositories | Where-Object { $_.id -eq $RepositoryId -and $_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$RepositoryId' was not found." }
}
else {
    $repository = @($config.repositories | Where-Object { $_.enabled }) | Select-Object -First 1
}
if (-not $Workspace -and $repository) { $Workspace = [string]$repository.localWorkspace }
if (-not $Workspace -or -not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "Workspace was not found: $Workspace" }
if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.git'))) { throw "Workspace is not a Git repository: $Workspace" }

$knowledgeImport = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$sync = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install
$task = & (Join-Path $PSScriptRoot 'New-AgentTask.ps1') -TaskId $TaskId -TaskSelector $TaskSelector -Mode $Mode -RepositoryId $RepositoryId -Resume:$Resume -ConfigPath $ConfigPath -CodexHome $CodexHome

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
Target workspace: $([IO.Path]::GetFullPath($Workspace))
Repository config ID: $RepositoryId
Additional user instruction: $UserInstruction
Execution mode: $executionMode ($workflowSandboxMode)

Live task control:
- The persistent ledger is $($task.TaskRoot)\task-ledger.jsonl.
- Before every agent handoff and after every agent result, reread the ledger and process every new user-comment event.
- User comments may clarify, pause, or redirect in-scope work, but they do not bypass approval gates or authorize unrelated external writes.
- Update visible per-agent state with $(Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') before and after every handoff. Use running, waiting, completed, failed, or skipped based only on evidence.
- When comments have been incorporated, record a user-comment-acknowledged event whose evidence contains the processed comment event IDs, then call Set-AgentTaskStatus.ps1 with -AcknowledgeComments.
- If user input is required, set the task to waiting_for_input and the affected agent to waiting. Do not invent an answer.
- Do not retry an identical failed execution more than $([int]$config.runtime.executionGuard.maxIdenticalFailures) times. On the third failure, stop immediately, persist the failure evidence, and hand it to development_health_check. Do not enter a wait loop after the retry limit.
- In elevated-approved mode, the user approved an OS-sandbox bypass for this task session. Every role may use the available local tools despite error 1260, but this does not authorize external writes, requirement assumptions, unapproved review fixes, or work outside the target workspace and ecosystem root.

Use the custom agents development_requirements_analyst, development_implementer, development_reviewer, development_pipeline_monitor, and development_health_check according to the configured gates. Dispatch development_health_check when an agent fails, a required artifact is missing or invalid, a workflow is stuck, or a dashboard/runtime contract fails. In automate mode, enumerate assigned tasks but process no more than $($config.operation.automate.maxTasksPerRun) tasks in this run. Do not implement held scope. Do not apply proposed review findings without explicit human decisions. Do not perform external writes without explicit authorization.

$($knowledgePrompt -join ([Environment]::NewLine + [Environment]::NewLine))
"@

$result = [pscustomobject]@{
    Mode = $Mode
    TaskId = $TaskId
    TaskRoot = $task.TaskRoot
    Workspace = [IO.Path]::GetFullPath($Workspace)
    ManagedKnowledgeRoot = $knowledgeImport.ManagedRoot
    AgentFiles = @($sync.AgentFiles)
    Prompt = $prompt
}
if ($PrepareOnly) { return $result }

$statusScript = Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1'
& $statusScript -TaskId $TaskId -Status running -Stage knowledge_keeper -Message 'Workflow started. Knowledge Keeper is preparing task context.' -ProcessId $PID -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
& $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus running -Stage knowledge_keeper -Message 'Knowledge Keeper is orchestrating the workflow.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$codexLogPath = Join-Path $task.TaskRoot 'workflow-codex.jsonl'
$finalResponsePath = Join-Path $task.TaskRoot 'workflow-final-response.md'
$guardArtifactPath = Join-Path $task.TaskRoot 'workflow-execution-guard.json'
$arguments = @(
    '-a', $workflowApprovalPolicy,
    'exec',
    '-C', [IO.Path]::GetFullPath($Workspace),
    '--add-dir', (Get-EcosystemRoot),
    '-s', $workflowSandboxMode,
    '--json',
    '-o', $finalResponsePath,
    '-'
)
try {
    $runHeader = [ordered]@{ type='ecosystem-workflow-run'; taskId=$TaskId; startedAtUtc=[DateTime]::UtcNow.ToString('o'); runner='codex exec' } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($codexLogPath, $runHeader + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $codexCommand = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codexCommand) { throw 'Codex CLI was not found.' }
    $guardResult = & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') -FilePath $codexCommand.Source -Arguments $arguments -Prompt $prompt -WorkingDirectory ([IO.Path]::GetFullPath($Workspace)) -LogPath $codexLogPath -GuardArtifactPath $guardArtifactPath -MaxIdenticalFailures ([int]$config.runtime.executionGuard.maxIdenticalFailures) -MaxRunMinutes ([int]$config.runtime.executionGuard.maxRunMinutes) -PollMilliseconds ([int]$config.runtime.executionGuard.pollMilliseconds)
    $codexExitCode = [int]$guardResult.exitCode
    if ([bool]$guardResult.guardTriggered) { throw [string]$guardResult.reason }
    if ($codexExitCode -ne 0) { throw "Codex exited with code $codexExitCode. See $codexLogPath" }
    $currentTask = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $currentStatus = [string]$currentTask.status
    $currentStage = if ($currentTask.PSObject.Properties['currentStage']) { [string]$currentTask.currentStage } else { $currentStatus }
    if ($currentStatus -in @('waiting_for_input','held')) {
        & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus waiting -Stage $currentStage -Message 'The orchestration run stopped at an explicit user-input gate.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    elseif ($currentStatus -eq 'review_pending') {
        & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus completed -Stage review_pending -Message 'Orchestration is waiting for human review decisions.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    elseif ($currentStatus -notin @('failed','interrupted','completed')) {
        & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus completed -Stage completed -Message 'Knowledge Keeper completed the orchestration run.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & $statusScript -TaskId $TaskId -Status completed -Stage completed -Message 'Workflow completed. Review task artifacts for the final outcome.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
}
catch {
    $failureMessage = $_.Exception.Message
    & $statusScript -TaskId $TaskId -AgentId knowledge_keeper -AgentStatus failed -Stage failed -Message $failureMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & $statusScript -TaskId $TaskId -Status failed -Stage failed -Message $failureMessage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $failureEvidence = @($codexLogPath, $finalResponsePath, $guardArtifactPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    $lastDiagnostic = if ((Get-Variable -Name guardResult -ErrorAction SilentlyContinue) -and [bool]$guardResult.guardTriggered) { [string]$guardResult.failureDetail } elseif (Test-Path -LiteralPath $codexLogPath -PathType Leaf) { (Get-Content -LiteralPath $codexLogPath -Tail 1 -Encoding UTF8 | Out-String).Trim() } else { $failureMessage }
    $failureExitCode = if (Get-Variable -Name codexExitCode -ErrorAction SilentlyContinue) { [Nullable[int]]$codexExitCode } else { $null }
    $failureHandoff = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId knowledge_keeper -Stage failed -Summary $failureMessage -ExitCode $failureExitCode -Diagnostic $lastDiagnostic -Evidence $failureEvidence -ConfigPath $ConfigPath -CodexHome $CodexHome
    if ([bool]$config.health.enabled -and [bool]$config.health.checkOnWorkflowFailure) {
        try { & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $TaskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Health check also failed: $($_.Exception.Message)" }
    }
    if ([bool]$config.health.automaticRecovery.enabled) {
        try { & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $TaskId -FailurePath $failureHandoff.FailurePath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null }
        catch { Write-Warning "Automatic health recovery failed: $($_.Exception.Message)" }
    }
    throw
}
