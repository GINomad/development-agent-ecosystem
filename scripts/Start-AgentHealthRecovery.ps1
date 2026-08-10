[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $FailurePath,
    [string] $DiagnosisPath,
    [switch] $ElevatedApproved,
    [switch] $OperatorApprovedDirtyWorktree,
    [ValidateRange(0,2)][int] $RecoveryDepth = 0,
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
    $message = "Failure signature $signature was already repaired and validated."
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_recovered -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus completed -Stage health_recovered -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $targetedResume = $null
    $successfulResultPath = [string]$successfulAttempt[0].resultPath
    if ([bool]$config.health.automaticRecovery.targetedResume.enabled -and (Test-Path -LiteralPath $successfulResultPath -PathType Leaf)) {
        $targetedParameters = @{ TaskId=$TaskId; FailurePath=$FailurePath; RecoveryEvidencePath=$successfulResultPath; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
        if ($ElevatedApproved) { $targetedParameters.ElevatedApproved = $true }
        $targetedResume = & (Join-Path $PSScriptRoot 'Start-HealthTargetedResume.ps1') @targetedParameters
    }
    return [pscustomobject]@{ Status='already-repaired'; TaskId=$TaskId; FailureSignature=$signature; ResultPath=$successfulResultPath; TargetedResume=$targetedResume }
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
if ($dirtyFiles.Count -and -not $OperatorApprovedDirtyWorktree) {
    $message = 'Automatic source recovery is waiting because the ecosystem repository has uncommitted changes.'
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary $message -NextStep 'Resolve or preserve the existing worktree changes before automatic repair.' -EvidenceRefs (@($FailurePath) + @($dirtyFiles)) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='dirty-worktree'; TaskId=$TaskId; Files=$dirtyFiles }
}
if ($OperatorApprovedDirtyWorktree -and -not $ElevatedApproved) {
    throw 'An operator-approved dirty-worktree recovery must also use the explicit elevated approval path.'
}

$attempt = [ordered]@{ type='recovery-started'; attemptId=[guid]::NewGuid().ToString('N'); failureSignature=$signature; executionMode=$executionMode; sandboxMode=$recoverySandboxMode; timestampUtc=[DateTime]::UtcNow.ToString('o') }
[IO.File]::AppendAllText($attemptsPath, ($attempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus running -Stage health_recovery -Message "Health Check Agent is repairing failure $signature." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$contextLimits = $config.runtime.contextLimits
$maximumBytes = [int]$contextLimits.maxCommandOutputBytes
$taskSnapshot = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$diagnosticContextPath = Join-Path $taskRoot 'health-diagnostic-context.json'
$existingDiagnosis = $null
if ($DiagnosisPath) {
    $resolvedDiagnosisPath = [IO.Path]::GetFullPath($DiagnosisPath)
    if (-not (Test-Path -LiteralPath $resolvedDiagnosisPath -PathType Leaf)) { throw "Health diagnosis was not found: $resolvedDiagnosisPath" }
    if ([IO.Path]::GetFullPath((Split-Path -Parent $resolvedDiagnosisPath)) -ne [IO.Path]::GetFullPath($taskRoot)) { throw 'Health diagnosis must be stored in the current task directory.' }
    $existingDiagnosis = Get-Content -LiteralPath $resolvedDiagnosisPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
$diagnosticContext = [ordered]@{
    taskId = $TaskId
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    failureSignature = $signature
    failure = $failure
    existingDiagnosis = $existingDiagnosis
    preExistingWorktreeChanges = if ($OperatorApprovedDirtyWorktree) { @($dirtyFiles) } else { @() }
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
$diagnosisInstruction = if ($existingDiagnosis) {
    'A completed Health Check diagnosis is included in existingDiagnosis. Do not invoke or delegate another diagnostic pass. Verify its cited evidence, then repair or route it.'
}
else {
    'First delegate evidence analysis to the custom agent development_health_check. Pass only the bounded diagnostic payload. Do not read complete workflow or ledger history.'
}
$dirtyInstruction = if ($OperatorApprovedDirtyWorktree) {
    'The operator explicitly approved this one recovery in a dirty ecosystem worktree. Preserve every pre-existing change listed in preExistingWorktreeChanges. Do not revert, overwrite wholesale, stage, commit, or clean those changes; make only the smallest additive repair needed for this failure.'
}
else { 'The ecosystem worktree was verified clean before recovery.' }
$healthPrompt = @"
You are the bounded recovery coordinator for the Development Agent Ecosystem.

Execution mode: $executionMode ($recoverySandboxMode). If this is elevated-approved, the user approved this one recovery attempt because the Windows sandbox failed with process-creation error 1260. The absence of an OS sandbox does not expand your authority: every read, write, and command must remain inside $workspace. Do not follow symlinks or junctions outside it.

Task: $TaskId
Bounded diagnostic artifact: $diagnosticContextPath
Bounded diagnostic payload (use this instead of reading complete historical logs):
$diagnosticJson
Ecosystem workspace: $workspace

$diagnosisInstruction
$dirtyInstruction

If the evidence identifies a source-controlled defect in this ecosystem, implement the smallest repair inside the ecosystem workspace. You may update ecosystem configuration, prompts, skills, dashboard, schemas, scripts, tests, and diagrams. You must not access or modify product repositories, weaken sandbox or approval gates, expose credentials, perform network or external writes, commit, push, delete task history, or start another workflow yourself. Preserve unrelated work. Run the exact failed check and scripts/Test-AgentEcosystem.ps1. If another configured role owns the repair, do not perform that role's work: return its agent ID in routeAgentId, set repairOwner consistently, and set requiresUserInput=false. Use Developer for product code, tests, or pipeline YAML; Requirements Analyst for unresolved requirements evidence; Knowledge Keeper for persisted knowledge/context contracts; Reviewer for review-process work; Pipeline Monitor for pipeline observation or provider-side diagnosis. Set routeAgentId=null when repaired here or when human input is required. Credentials, external authority, approval decisions, and genuinely ambiguous evidence require repairOwner=human and requiresUserInput=true. After a validated ecosystem repair, the trusted host coordinator may perform the configured one-shot targeted retry of only the failed agent.

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

$recoveryWasValidated = $false
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
    $routedAgentId = ''

    if ([string]$recovery.status -eq 'repaired') {
        $validation = & (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_recovered -Message 'Health recovery passed validation. Preparing the configured one-shot targeted retry.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $TaskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus completed -Stage health_recovered -Message "Health recovery completed and $(@($validation.Checks).Count) ecosystem checks passed." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $recoveryWasValidated = $true
    }
    elseif ([string]$recovery.status -eq 'needs-user-input') {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status waiting_for_input -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    else {
        $routedAgentId = if ($recovery.PSObject.Properties['routeAgentId']) { [string]$recovery.routeAgentId } else { '' }
        $requiresUserInput = $recovery.PSObject.Properties['requiresUserInput'] -and [bool]$recovery.requiresUserInput
        if ($routedAgentId -and -not $requiresUserInput) {
            if ($routedAgentId -notin @($config.health.automaticRecovery.targetedResume.allowedAgentIds)) { throw "Health recovery selected forbidden repair owner '$routedAgentId'." }
            $routingPath = Join-Path $taskRoot 'health-repair-routing.json'
            $routing = [ordered]@{ taskId=$TaskId; failureSignature=$signature; sourceAgentId=[string]$failure.agentId; targetAgentId=$routedAgentId; repairOwner=[string]$recovery.repairOwner; reason=[string]$recovery.rootCause; instruction=[string]$recovery.nextAction; failurePath=[IO.Path]::GetFullPath($FailurePath); recoveryResultPath=$resultPath; createdAtUtc=[DateTime]::UtcNow.ToString('o'); status='pending' }
            Write-Utf8NoBom -Path $routingPath -Content (($routing | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId $routedAgentId -AgentStatus pending -Stage health_repair_routed -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_repair_routed -Message "Health Check routed the repair to '$routedAgentId'." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type workflow-status -Summary "Health Check routed a bounded repair to '$routedAgentId'." -Artifact $routingPath -Evidence @($FailurePath, $resultPath) -TargetAgentId $routedAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        else {
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message ([string]$recovery.nextAction) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    $completedAttempt = [ordered]@{ type='recovery-completed'; attemptId=$attempt.attemptId; failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o'); status=[string]$recovery.status; resultPath=$resultPath }
    [IO.File]::AppendAllText($attemptsPath, ($completedAttempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $targetedResume = $null
    if ([string]$recovery.status -eq 'repaired' -and [bool]$config.health.automaticRecovery.targetedResume.enabled) {
        $targetedParameters = @{
            TaskId = $TaskId
            FailurePath = $FailurePath
            RecoveryEvidencePath = $resultPath
            ConfigPath = $ConfigPath
            CodexHome = $CodexHome
        }
        if ($ElevatedApproved) { $targetedParameters.ElevatedApproved = $true }
        $targetedResume = & (Join-Path $PSScriptRoot 'Start-HealthTargetedResume.ps1') @targetedParameters
    }
    elseif ($routedAgentId) {
        $routingPath = Join-Path $taskRoot 'health-repair-routing.json'
        $taskSnapshot = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $repositoryIds = if ($taskSnapshot.PSObject.Properties['repositoryIds']) { @($taskSnapshot.repositoryIds) } elseif ($taskSnapshot.PSObject.Properties['repositoryId']) { @([string]$taskSnapshot.repositoryId) } else { @() }
        $routeParameters = @{ Mode=[string]$taskSnapshot.mode; TaskSelector=[string]$taskSnapshot.selector; TaskId=$TaskId; RepositoryIds=@($repositoryIds); UserInstruction="Health Check routed this repair to '$routedAgentId'. Read $routingPath and the bounded evidence it references. Fix only the assigned scope, preserve completed agents and artifacts, and stop for user input when authority or facts are missing."; Resume=$true; TargetAgentId=$routedAgentId; ContinueChain=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
        if ($ElevatedApproved) { $routeParameters.ElevatedApproved = $true }
        $targetedResume = & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @routeParameters
    }
    if ([string]$recovery.status -ne 'repaired' -and -not $routedAgentId) {
        & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary "Automatic health recovery finished with status $([string]$recovery.status)." -NextStep ([string]$recovery.nextAction) -EvidenceRefs @($FailurePath, $resultPath, $logPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    if ($targetedResume -and [string]$targetedResume.Status -eq 'failed' -and $RecoveryDepth -lt 2) {
        $followupFailurePath = $null
        foreach ($candidate in @(Get-ChildItem -LiteralPath $taskRoot -Filter 'agent-failure-*.json' -File | Sort-Object LastWriteTimeUtc -Descending)) {
            try { $candidateFailure = Get-Content -LiteralPath $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ([string]$candidateFailure.failureSignature -ne $signature -and [string]$candidateFailure.agentId -eq [string]$failure.agentId) { $followupFailurePath = $candidate.FullName; break }
        }
        if ($followupFailurePath) {
            & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level progress -Stage health_recovery_followup -Summary "The targeted '$([string]$failure.agentId)' retry returned failed; Health Check accepted its new bounded failure envelope." -Details "Recovery depth $($RecoveryDepth + 1) of 2; failure: $followupFailurePath" -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $followupParameters = @{ TaskId=$TaskId; FailurePath=$followupFailurePath; RecoveryDepth=($RecoveryDepth + 1); ConfigPath=$ConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved) { $followupParameters.ElevatedApproved = $true }
            if ($OperatorApprovedDirtyWorktree) { $followupParameters.OperatorApprovedDirtyWorktree = $true }
            return & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') @followupParameters
        }
    }
    [pscustomobject]@{ Status=[string]$recovery.status; TaskId=$TaskId; FailureSignature=$signature; ResultPath=$resultPath; LogPath=$logPath; TargetedResume=$targetedResume }
}
catch {
    $failedAttempt = [ordered]@{ type='recovery-failed'; attemptId=$attempt.attemptId; failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message }
    [IO.File]::AppendAllText($attemptsPath, ($failedAttempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    if ($recoveryWasValidated -and $RecoveryDepth -lt 2) {
        $followupSummary = "Post-repair targeted resume failed before '$([string]$failure.agentId)' could complete: $($_.Exception.Message)"
        $followupEvidence = @($FailurePath, $resultPath, (Join-Path $PSScriptRoot 'Start-HealthTargetedResume.ps1'))
        $followup = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId ([string]$failure.agentId) -Stage health_targeted_resume -Summary $followupSummary -Diagnostic $_.Exception.ToString() -Evidence $followupEvidence -ConfigPath $ConfigPath -CodexHome $CodexHome
        & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level progress -Stage health_recovery_followup -Summary 'A validated repair exposed a different ecosystem failure during targeted resume; Health Check accepted the new bounded failure envelope.' -Details "Recovery depth $($RecoveryDepth + 1) of 2; failure: $([string]$followup.FailurePath)" -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $followupParameters = @{ TaskId=$TaskId; FailurePath=[string]$followup.FailurePath; RecoveryDepth=($RecoveryDepth + 1); ConfigPath=$ConfigPath; CodexHome=$CodexHome }
        if ($ElevatedApproved) { $followupParameters.ElevatedApproved = $true }
        if ($OperatorApprovedDirtyWorktree) { $followupParameters.OperatorApprovedDirtyWorktree = $true }
        return & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') @followupParameters
    }
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus failed -Stage health_recovery -Message $_.Exception.Message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    throw
}
