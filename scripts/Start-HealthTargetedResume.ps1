[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $FailurePath,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $ExecutionRunId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $WorkspaceLeaseId,
    [Parameter(Mandatory)][string] $RecoveryEvidencePath,
    [switch] $ElevatedApproved,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ([bool]$config.runtime.elevatedFallback.useByDefault) { $ElevatedApproved = $true }
$targetedConfig = $config.health.automaticRecovery.targetedResume
if (-not [bool]$targetedConfig.enabled) {
    return [pscustomobject]@{ Status='disabled'; TaskId=$TaskId; TargetAgentId=$null }
}

$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

function Resolve-TaskArtifactPath {
    param([Parameter(Mandatory)][string] $Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($taskRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery input must stay inside the task artifact root: $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Recovery input was not found: $resolved" }
    return $resolved
}

$resolvedFailurePath = Resolve-TaskArtifactPath -Path $FailurePath
$resolvedRecoveryEvidencePath = Resolve-TaskArtifactPath -Path $RecoveryEvidencePath
$failure = Get-Content -LiteralPath $resolvedFailurePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$failure.taskId -ne $TaskId) { throw 'Failure artifact task ID does not match the requested task.' }
$targetAgentId = [string]$failure.agentId
$allowedAgentIds = @($targetedConfig.allowedAgentIds | ForEach-Object { [string]$_ })
if ($targetAgentId -notin $allowedAgentIds) {
    return [pscustomobject]@{ Status='not-eligible'; TaskId=$TaskId; TargetAgentId=$targetAgentId; FailureSignature=[string]$failure.failureSignature }
}

$recoveryEvidence = Get-Content -LiteralPath $resolvedRecoveryEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
$failureSignature = [string]$failure.failureSignature
$confirmedModelRepair = $recoveryEvidence.PSObject.Properties['failureSignature'] -and
    [string]$recoveryEvidence.failureSignature -eq $failureSignature -and
    [string]$recoveryEvidence.status -eq 'repaired'
$diagnosticText = @([string]$failure.summary, [string]$failure.diagnostic) -join [Environment]::NewLine
$requiresHostCompatibleProfile = $diagnosticText -match 'CreateProcessWithLogonW|Windows sandbox|error\s*1260'
$confirmedCompatibilityRepair = $false
if ($requiresHostCompatibleProfile -and $recoveryEvidence.PSObject.Properties['checks']) {
    $confirmedCompatibilityRepair = @($recoveryEvidence.checks | Where-Object {
        [string]$_.id -eq 'os-policy-compatibility' -and [string]$_.status -eq 'repaired'
    }).Count -gt 0
}
if ([bool]$targetedConfig.requireSuccessfulRepair -and -not ($confirmedModelRepair -or $confirmedCompatibilityRepair)) {
    throw 'Targeted resume requires matching evidence of a successfully validated repair.'
}

$resultPath = Join-Path $taskRoot 'health-targeted-resume.json'
$attemptsPath = Join-Path $taskRoot 'health-targeted-resume-attempts.jsonl'
function Write-TargetedResult {
    param(
        [Parameter(Mandatory)][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [int] $AttemptCount = 0,
        [string] $FinalAgentStatus = ''
    )
    $result = [ordered]@{
        taskId = $TaskId
        failureSignature = $failureSignature
        targetAgentId = $targetAgentId
        status = $Status
        executionMode = if ($ElevatedApproved) { 'elevated-approved' } else { 'sandboxed' }
        attemptCount = $AttemptCount
        finalAgentStatus = if ($FinalAgentStatus) { $FinalAgentStatus } else { $null }
        recoveryEvidencePath = $resolvedRecoveryEvidencePath
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        message = $Message
    }
    Write-Utf8NoBom -Path $resultPath -Content (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return [pscustomobject]$result
}

if ($requiresHostCompatibleProfile -and -not $ElevatedApproved) {
    $message = "Health Check prepared host-compatible profiles, but standing host-compatible execution is unavailable for '$targetAgentId'."
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level waiting -Stage health_targeted_resume -Summary $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return Write-TargetedResult -Status 'approval-required' -Message $message
}
if ($ElevatedApproved) {
    if (-not [bool]$config.runtime.elevatedFallback.enabled) {
        throw 'Host-compatible targeted resume is not enabled.'
    }
}

$attempts = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $attemptsPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $attemptsPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $attempts.Add(($line | ConvertFrom-Json)) } catch { }
    }
}
$attemptCount = @($attempts | Where-Object {
    [string]$_.type -eq 'targeted-resume-started' -and
    [string]$_.failureSignature -eq $failureSignature -and
    [string]$_.targetAgentId -eq $targetAgentId
}).Count
$maximumAttempts = [int]$targetedConfig.maxAttemptsPerFailureSignature
if ($attemptCount -ge $maximumAttempts) {
    $message = "Automatic targeted resume limit reached for '$targetAgentId' and failure signature $failureSignature."
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_targeted_resume_limit -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return Write-TargetedResult -Status 'attempt-limit' -Message $message -AttemptCount $attemptCount
}

$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$task.status -eq 'running' -and $task.PSObject.Properties['workflowProcessId']) {
    $activeProcess = Get-Process -Id ([int]$task.workflowProcessId) -ErrorAction SilentlyContinue
    if ($activeProcess) {
        return Write-TargetedResult -Status 'busy' -Message "Task '$TaskId' already has a live workflow process." -AttemptCount $attemptCount
    }
}
$repositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) {
    @($task.repositoryIds | ForEach-Object { [string]$_ })
}
elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) {
    @([string]$task.repositoryId)
}
else { @() })
if (-not $repositoryIds.Count) { throw "Task '$TaskId' does not persist a repository scope." }

$launchPlan = [pscustomobject][ordered]@{
    TaskId = $TaskId
    TargetAgentId = $targetAgentId
    FailureSignature = $failureSignature
    Mode = [string]$task.mode
    TaskSelector = [string]$task.selector
    RepositoryIds = @($repositoryIds)
    ElevatedApproved = [bool]$ElevatedApproved
    AttemptNumber = $attemptCount + 1
}
if ($PrepareOnly) { return $launchPlan }

$attempt = [ordered]@{
    type = 'targeted-resume-started'
    attemptId = [guid]::NewGuid().ToString('N')
    failureSignature = $failureSignature
    targetAgentId = $targetAgentId
    executionMode = if ($ElevatedApproved) { 'elevated-approved' } else { 'sandboxed' }
    timestampUtc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::AppendAllText($attemptsPath, ($attempt | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
& (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level progress -Stage health_targeted_resume -Summary "Validated repair is restarting only '$targetAgentId'." -Details "Failure signature $failureSignature; attempt $($attemptCount + 1) of $maximumAttempts. Other agents remain unchanged." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type workflow-status -Summary "Health Check scheduled a targeted resume for '$targetAgentId' after validated repair." -Artifact $resolvedRecoveryEvidencePath -Evidence @($resolvedFailurePath, $resolvedRecoveryEvidencePath) -TargetAgentId $targetAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

$workflowParameters = @{
    Mode = [string]$task.mode
    TaskSelector = [string]$task.selector
    TaskId = $TaskId
    RepositoryIds = @($repositoryIds)
    UserInstruction = "Health Check validated repair for failure signature $failureSignature. Resume only '$targetAgentId' from its private checkpoint; preserve every other agent and completed artifact."
    Resume = $true
    TargetAgentId = $targetAgentId
    HealthRecoveryRetry = $true
    ContinueChain = $true
    ConfigPath = $ConfigPath
    CodexHome = $CodexHome
}
if ($ExecutionRunId) { $workflowParameters.ExecutionRunId = $ExecutionRunId }
if ($WorkspaceLeaseId) { $workflowParameters.WorkspaceLeaseId = $WorkspaceLeaseId }
if ($ElevatedApproved) { $workflowParameters.ElevatedApproved = $true }

try {
    & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @workflowParameters | Out-Null
    $finalTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $finalAgentStatus = [string]$finalTask.agentStatuses.$targetAgentId.status
    $resumeStatus = if ($finalAgentStatus -eq 'completed') { 'completed' } elseif ($finalAgentStatus -eq 'waiting') { 'waiting' } elseif ($finalAgentStatus -eq 'failed') { 'failed' } else { 'interrupted' }
    $message = "Automatic targeted resume finished for '$targetAgentId' with status '$finalAgentStatus'."
    $completed = [ordered]@{
        type = 'targeted-resume-completed'
        attemptId = $attempt.attemptId
        failureSignature = $failureSignature
        targetAgentId = $targetAgentId
        status = $resumeStatus
        finalAgentStatus = $finalAgentStatus
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::AppendAllText($attemptsPath, ($completed | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId health_check -Level $(if ($resumeStatus -eq 'completed') { 'success' } elseif ($resumeStatus -eq 'failed') { 'error' } else { 'waiting' }) -Stage health_targeted_resume -Summary $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return Write-TargetedResult -Status $resumeStatus -Message $message -AttemptCount ($attemptCount + 1) -FinalAgentStatus $finalAgentStatus
}
catch {
    $message = "Automatic targeted resume failed for '$targetAgentId': $($_.Exception.Message)"
    $failed = [ordered]@{
        type = 'targeted-resume-failed'
        attemptId = $attempt.attemptId
        failureSignature = $failureSignature
        targetAgentId = $targetAgentId
        status = 'failed'
        error = $_.Exception.Message
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::AppendAllText($attemptsPath, ($failed | ConvertTo-Json -Compress) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage health_targeted_resume_failed -Message $message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return Write-TargetedResult -Status 'failed' -Message $message -AttemptCount ($attemptCount + 1) -FinalAgentStatus 'failed'
}
