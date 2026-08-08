[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $FailurePath,
    [switch] $ElevatedApproved,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome

function Get-BoundedTextTail {
    param([string] $Path, [int] $TailLines, [int] $MaximumBytes)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = (@(Get-Content -LiteralPath $Path -Tail $TailLines -Encoding UTF8) -join [Environment]::NewLine)
    $encoding = New-Object Text.UTF8Encoding($false, $false)
    $bytes = $encoding.GetBytes($text)
    if ($bytes.Length -le $MaximumBytes) { return $text }
    $offset = $bytes.Length - $MaximumBytes
    return '[truncated to configured byte tail]' + [Environment]::NewLine + $encoding.GetString($bytes, $offset, $MaximumBytes)
}
if (-not [bool]$config.health.automaticRecovery.enabled) { return [pscustomobject]@{ Status='disabled'; TaskId=$TaskId } }
if (-not (Test-Path -LiteralPath $FailurePath -PathType Leaf)) { throw "Failure artifact was not found: $FailurePath" }

$workspace = Resolve-EcosystemPath -Value ([string]$config.health.automaticRecovery.workspace) -Config $config -CodexHome $CodexHome
if ([IO.Path]::GetFullPath($workspace) -ne [IO.Path]::GetFullPath((Get-EcosystemRoot))) { throw 'Automatic health recovery workspace must be the ecosystem repository root.' }
if ([bool]$config.health.automaticRecovery.allowProductCodeChanges -or [bool]$config.health.automaticRecovery.allowExternalWrites) { throw 'Automatic recovery boundary is invalid.' }
$executionMode = if ($ElevatedApproved) { 'elevated-approved' } else { 'sandboxed' }
if ($ElevatedApproved) {
    if (-not [bool]$config.health.automaticRecovery.elevatedFallback.enabled -or -not [bool]$config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Elevated recovery is not enabled with an explicit approval gate.' }
    $recoverySandboxMode = [string]$config.health.automaticRecovery.elevatedFallback.sandboxMode
    $maximumAttempts = [int]$config.health.automaticRecovery.elevatedFallback.maxAttemptsPerFailureSignature
    $recoveryApprovalPolicy = 'never'
}
else {
    $recoverySandboxMode = [string]$config.health.automaticRecovery.sandboxMode
    $maximumAttempts = [int]$config.health.automaticRecovery.maxAttemptsPerFailureSignature
    $recoveryApprovalPolicy = [string]$config.runtime.approvalPolicy
}
if ($recoverySandboxMode -notin @('workspace-write','danger-full-access')) { throw 'Automatic recovery sandbox boundary is invalid.' }

$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$failure = Get-Content -LiteralPath $FailurePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$failure.taskId -ne $TaskId) { throw 'Failure artifact task ID does not match the requested task.' }
$signature = [string]$failure.failureSignature

$attemptsPath = Join-Path $taskRoot 'health-recovery-attempts.jsonl'
$attempts = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $attemptsPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $attemptsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $attempts.Add(($line | ConvertFrom-Json)) } catch { }
    }
}
$successfulAttempt = @($attempts | Where-Object { $_.failureSignature -eq $signature -and $_.type -eq 'recovery-completed' -and [string]$_.status -eq 'repaired' } | Select-Object -Last 1)
if ($successfulAttempt.Count) {
    $message = "Failure signature $signature was already repaired and validated. Resume the workflow when ready."
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_recovered -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus completed -Stage health_recovered -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='already-repaired'; TaskId=$TaskId; FailureSignature=$signature; ResultPath=[string]$successfulAttempt[0].resultPath }
}
$attemptCount = @($attempts | Where-Object {
    $recordExecutionMode = if ($_.PSObject.Properties['executionMode']) { [string]$_.executionMode } else { 'sandboxed' }
    $_.failureSignature -eq $signature -and $_.type -eq 'recovery-started' -and
    ($(if ($ElevatedApproved) { $recordExecutionMode -eq 'elevated-approved' } else { $recordExecutionMode -ne 'elevated-approved' }))
}).Count
if ($attemptCount -ge $maximumAttempts) {
    $message = "Automatic recovery limit reached for failure signature $signature."
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary $message -NextStep 'A human must inspect or approve the next bounded recovery action.' -EvidenceRefs @($FailurePath, $attemptsPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='attempt-limit'; TaskId=$TaskId; FailureSignature=$signature; Attempts=$attemptCount }
}

$dirtyFiles = @(git -C $workspace status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the ecosystem Git worktree.' }
if ($dirtyFiles.Count) {
    $message = 'Automatic source recovery is waiting because the ecosystem repository has uncommitted changes.'
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary $message -NextStep 'Resolve or preserve the existing worktree changes before automatic repair.' -EvidenceRefs (@($FailurePath) + @($dirtyFiles)) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='dirty-worktree'; TaskId=$TaskId; Files=$dirtyFiles }
}

$attempt = [ordered]@{ type='recovery-started'; attemptId=[guid]::NewGuid().ToString('N'); failureSignature=$signature; executionMode=$executionMode; sandboxMode=$recoverySandboxMode; timestampUtc=[DateTime]::UtcNow.ToString('o') }
[IO.File]::AppendAllText($attemptsPath, ($attempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus running -Stage health_recovery -Message "Health Check Agent is repairing failure $signature." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$contextLimits = $config.runtime.contextLimits
$maximumBytes = [int]$contextLimits.maxCommandOutputBytes
$taskSnapshot = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$diagnosticContextPath = Join-Path $taskRoot 'health-diagnostic-context.json'
$diagnosticContext = [ordered]@{
    taskId = $TaskId
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    failureSignature = $signature
    failure = $failure
    taskStatus = [ordered]@{
        status = [string]$taskSnapshot.status
        stage = if ($taskSnapshot.PSObject.Properties['currentStage']) { [string]$taskSnapshot.currentStage } else { [string]$taskSnapshot.status }
        message = if ($taskSnapshot.PSObject.Properties['lastMessage']) { [string]$taskSnapshot.lastMessage } else { '' }
    }
    workflowLogTail = Get-BoundedTextTail -Path (Join-Path $taskRoot 'workflow-codex.jsonl') -TailLines ([int]$contextLimits.workflowLogTailLines) -MaximumBytes $maximumBytes
    ledgerTail = Get-BoundedTextTail -Path (Join-Path $taskRoot 'task-ledger.jsonl') -TailLines ([int]$contextLimits.ledgerTailLines) -MaximumBytes $maximumBytes
    finalResponseTail = Get-BoundedTextTail -Path (Join-Path $taskRoot 'workflow-final-response.md') -TailLines ([int]$contextLimits.ledgerTailLines) -MaximumBytes $maximumBytes
    limits = [ordered]@{ workflowLogTailLines=[int]$contextLimits.workflowLogTailLines; ledgerTailLines=[int]$contextLimits.ledgerTailLines; maximumBytesPerTail=$maximumBytes }
}
$diagnosticJson = $diagnosticContext | ConvertTo-Json -Depth 20
Write-Utf8NoBom -Path $diagnosticContextPath -Content ($diagnosticJson + [Environment]::NewLine)
$healthPrompt = @"
You are the bounded recovery coordinator for the Development Agent Ecosystem.

Execution mode: $executionMode ($recoverySandboxMode). If this is elevated-approved, the user approved this one recovery attempt because the Windows sandbox failed with process-creation error 1260. The absence of an OS sandbox does not expand your authority: every read, write, and command must remain inside $workspace. Do not follow symlinks or junctions outside it.

Task: $TaskId
Bounded diagnostic artifact: $diagnosticContextPath
Bounded diagnostic payload (use this instead of reading complete historical logs):
$diagnosticJson
Ecosystem workspace: $workspace

First delegate evidence analysis to the custom agent development_health_check. Pass only the bounded diagnostic payload. Do not read complete workflow or ledger history. Then, only if the evidence identifies a source-controlled defect in this ecosystem, implement the smallest repair inside the ecosystem workspace. You may update ecosystem configuration, prompts, skills, dashboard, schemas, scripts, tests, and diagrams. You must not access or modify product repositories, weaken sandbox or approval gates, expose credentials, perform network or external writes, commit, push, delete task history, or retry another workflow. Preserve unrelated work. Run the exact failed check and scripts/Test-AgentEcosystem.ps1. If evidence is insufficient or user input is needed, do not invent a fix.

Return only the JSON object required by the configured output schema. Use the exact failure signature $signature.
"@

$logPath = Join-Path $taskRoot 'health-recovery-codex.jsonl'
$resultPath = Join-Path $taskRoot 'health-recovery-result.json'
$guardArtifactPath = Join-Path $taskRoot 'health-recovery-execution-guard.json'
$schemaPath = Join-Path (Get-EcosystemRoot) 'config\schemas\health-recovery-result.schema.json'
$arguments = @(
    '-a', $recoveryApprovalPolicy,
    'exec',
    '-C', $workspace,
    '-s', $recoverySandboxMode,
    '--json',
    '--output-schema', $schemaPath,
    '-o', $resultPath,
    '-'
)

try {
    $codexCommand = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codexCommand) { throw 'Codex CLI was not found.' }
    $guardResult = & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') -FilePath $codexCommand.Source -Arguments $arguments -Prompt $healthPrompt -WorkingDirectory $workspace -LogPath $logPath -GuardArtifactPath $guardArtifactPath -MaxIdenticalFailures ([int]$config.runtime.executionGuard.maxIdenticalFailures) -MaxRunMinutes ([int]$config.runtime.executionGuard.maxRunMinutes) -PollMilliseconds ([int]$config.runtime.executionGuard.pollMilliseconds)
    $codexExitCode = [int]$guardResult.exitCode
    if ([bool]$guardResult.guardTriggered) { throw [string]$guardResult.reason }
    if ($codexExitCode -ne 0) { throw "Health recovery Codex exited with code $codexExitCode. See $logPath" }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw 'Health recovery did not produce its required result artifact.' }
    $recovery = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$recovery.failureSignature -ne $signature) { throw 'Health recovery result has the wrong failure signature.' }

    if ([string]$recovery.status -eq 'repaired') {
        $validation = & (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_recovered -Message 'Health recovery passed validation. Resume the workflow to retry the task.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $TaskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus completed -Stage health_recovered -Message "Health recovery completed and $(@($validation.Checks).Count) ecosystem checks passed." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    elseif ([string]$recovery.status -eq 'needs-user-input') {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status waiting_for_input -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    else {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    $completedAttempt = [ordered]@{ type='recovery-completed'; attemptId=$attempt.attemptId; failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o'); status=[string]$recovery.status; resultPath=$resultPath }
    [IO.File]::AppendAllText($attemptsPath, ($completedAttempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    if ([string]$recovery.status -ne 'repaired') {
        & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary "Automatic health recovery finished with status $([string]$recovery.status)." -NextStep ([string]$recovery.nextAction) -EvidenceRefs @($FailurePath, $resultPath, $logPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    [pscustomobject]@{ Status=[string]$recovery.status; TaskId=$TaskId; FailureSignature=$signature; ResultPath=$resultPath; LogPath=$logPath }
}
catch {
    $failedAttempt = [ordered]@{ type='recovery-failed'; attemptId=$attempt.attemptId; failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message }
    [IO.File]::AppendAllText($attemptsPath, ($failedAttempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus failed -Stage health_recovery -Message $_.Exception.Message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    throw
}
