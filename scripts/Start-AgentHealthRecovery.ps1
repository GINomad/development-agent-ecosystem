[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $FailurePath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.health.automaticRecovery.enabled) { return [pscustomobject]@{ Status='disabled'; TaskId=$TaskId } }
if (-not (Test-Path -LiteralPath $FailurePath -PathType Leaf)) { throw "Failure artifact was not found: $FailurePath" }

$workspace = Resolve-EcosystemPath -Value ([string]$config.health.automaticRecovery.workspace) -Config $config -CodexHome $CodexHome
if ([IO.Path]::GetFullPath($workspace) -ne [IO.Path]::GetFullPath((Get-EcosystemRoot))) { throw 'Automatic health recovery workspace must be the ecosystem repository root.' }
if ([bool]$config.health.automaticRecovery.allowProductCodeChanges -or [bool]$config.health.automaticRecovery.allowExternalWrites) { throw 'Automatic recovery boundary is invalid.' }

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
$attemptCount = @($attempts | Where-Object { $_.failureSignature -eq $signature -and $_.type -eq 'recovery-started' }).Count
$maximumAttempts = [int]$config.health.automaticRecovery.maxAttemptsPerFailureSignature
if ($attemptCount -ge $maximumAttempts) {
    $message = "Automatic recovery limit reached for failure signature $signature."
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type agent-result -Summary $message -Artifact $attemptsPath -Evidence @($FailurePath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='attempt-limit'; TaskId=$TaskId; FailureSignature=$signature; Attempts=$attemptCount }
}

$dirtyFiles = @(git -C $workspace status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the ecosystem Git worktree.' }
if ($dirtyFiles.Count) {
    $message = 'Automatic source recovery is waiting because the ecosystem repository has uncommitted changes.'
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_check -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type agent-result -Summary $message -Artifact $FailurePath -Evidence @($dirtyFiles) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='dirty-worktree'; TaskId=$TaskId; Files=$dirtyFiles }
}

$attempt = [ordered]@{ type='recovery-started'; attemptId=[guid]::NewGuid().ToString('N'); failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o') }
[IO.File]::AppendAllText($attemptsPath, ($attempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus running -Stage health_recovery -Message "Health Check Agent is repairing failure $signature." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$failureJson = Get-Content -LiteralPath $FailurePath -Raw -Encoding UTF8
$healthPrompt = @"
You are the bounded recovery coordinator for the Development Agent Ecosystem.

Task: $TaskId
Failure artifact: $FailurePath
Failure payload:
$failureJson
Ecosystem workspace: $workspace

First delegate evidence analysis to the custom agent development_health_check. Then, only if the evidence identifies a source-controlled defect in this ecosystem, implement the smallest repair inside the ecosystem workspace. You may update ecosystem configuration, prompts, skills, dashboard, schemas, scripts, tests, and diagrams. You must not access or modify product repositories, weaken sandbox or approval gates, expose credentials, perform network or external writes, commit, push, delete task history, or retry another workflow. Preserve unrelated work. Run the exact failed check and scripts/Test-AgentEcosystem.ps1. If evidence is insufficient or user input is needed, do not invent a fix.

Return only the JSON object required by the configured output schema. Use the exact failure signature $signature.
"@

$logPath = Join-Path $taskRoot 'health-recovery-codex.jsonl'
$resultPath = Join-Path $taskRoot 'health-recovery-result.json'
$schemaPath = Join-Path (Get-EcosystemRoot) 'config\schemas\health-recovery-result.schema.json'
$arguments = @(
    '-a', [string]$config.runtime.approvalPolicy,
    'exec',
    '-C', $workspace,
    '-s', 'workspace-write',
    '-c', "agents.max_concurrent_threads_per_session=$([int]$config.runtime.maxConcurrentAgents)",
    '--json',
    '--output-schema', $schemaPath,
    '-o', $resultPath,
    $healthPrompt
)

try {
    & codex @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        [IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Write-Output $line
    }
    $codexExitCode = $LASTEXITCODE
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
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type agent-result -Summary "Automatic health recovery finished with status $([string]$recovery.status)." -Artifact $resultPath -Evidence @($FailurePath, $logPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    [pscustomobject]@{ Status=[string]$recovery.status; TaskId=$TaskId; FailureSignature=$signature; ResultPath=$resultPath; LogPath=$logPath }
}
catch {
    $failedAttempt = [ordered]@{ type='recovery-failed'; attemptId=$attempt.attemptId; failureSignature=$signature; timestampUtc=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message }
    [IO.File]::AppendAllText($attemptsPath, ($failedAttempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus failed -Stage health_recovery -Message $_.Exception.Message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    throw
}

