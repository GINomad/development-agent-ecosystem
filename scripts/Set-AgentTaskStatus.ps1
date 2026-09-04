[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [ValidateSet('created','queued','running','waiting_for_input','held','review_pending','completed','failed','interrupted')][string] $Status,
    [ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [ValidateSet('pending','running','waiting','completed','failed','skipped')][string] $AgentStatus,
    [string] $Stage,
    [string] $Message,
    [int] $ProcessId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $ExecutionRunId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $WorkspaceLeaseId,
    [switch] $ClearProcessId,
    [string] $Actor = 'ecosystem',
    [switch] $AcknowledgeComments,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ($AgentId -and -not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
if (-not $Status -and -not $AgentId -and -not $Stage -and -not $Message -and -not $AcknowledgeComments -and -not $ClearProcessId -and -not $ExecutionRunId -and -not $WorkspaceLeaseId) {
    throw 'Specify a task status, agent status, stage, message, or comment acknowledgement.'
}
if ([bool]$AgentId -xor [bool]$AgentStatus) { throw 'AgentId and AgentStatus must be supplied together.' }
if ($AgentId -and (($ProcessId -gt 0) -or $ExecutionRunId -or $WorkspaceLeaseId -or $ClearProcessId)) {
    throw 'Agent status updates cannot set controller-owned process, run, or workspace lease fields.'
}
if ([bool]$ExecutionRunId -xor [bool]$WorkspaceLeaseId) {
    throw 'ExecutionRunId and WorkspaceLeaseId must be supplied together.'
}

$taskLockPath = Join-Path $taskRoot 'task-state.lock'
$now = [DateTime]::UtcNow.ToString('o')
$updateTaskState = {
    $document = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Status) { $document | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force }
    if ($Stage) { $document | Add-Member -NotePropertyName currentStage -NotePropertyValue $Stage -Force }
    if ($Message -and (-not $AgentId -or $Status)) { $document | Add-Member -NotePropertyName lastMessage -NotePropertyValue $Message -Force }
    if ($ProcessId -gt 0) { $document | Add-Member -NotePropertyName workflowProcessId -NotePropertyValue $ProcessId -Force }
    if ($ExecutionRunId) { $document | Add-Member -NotePropertyName executionRunId -NotePropertyValue $ExecutionRunId -Force }
    if ($WorkspaceLeaseId) { $document | Add-Member -NotePropertyName workspaceLeaseId -NotePropertyValue $WorkspaceLeaseId -Force }
    if ($ExecutionRunId -or $WorkspaceLeaseId) { $document | Add-Member -NotePropertyName workflowHeartbeatAtUtc -NotePropertyValue $now -Force }
    if ($ClearProcessId -and $document.PSObject.Properties['workflowProcessId']) { $document.PSObject.Properties.Remove('workflowProcessId') }
    if ($AcknowledgeComments) {
        $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
        $events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) } else { @() }
        $acknowledged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($ack in @($events | Where-Object { [string]$_.type -eq 'user-comment-acknowledged' })) {
            foreach ($value in @($ack.evidence)) { if ($value) { $null = $acknowledged.Add([string]$value) } }
        }
        $hasUnreadComments = @($events | Where-Object { [string]$_.type -in @('user-comment','workflow-input-routed') -and -not $acknowledged.Contains([string]$_.eventId) }).Count -gt 0
        $document | Add-Member -NotePropertyName hasUnreadUserComments -NotePropertyValue $hasUnreadComments -Force
    }
    $document | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force

    if (-not $document.PSObject.Properties['agentStatuses']) {
        $document | Add-Member -NotePropertyName agentStatuses -NotePropertyValue ([pscustomobject]@{})
    }
    if ($AgentId) {
        $agentValue = [pscustomobject][ordered]@{ status=$AgentStatus; updatedAtUtc=$now; message=if ($Message) { $Message } else { '' } }
        $document.agentStatuses | Add-Member -NotePropertyName $AgentId -NotePropertyValue $agentValue -Force
        if ($Message) { $document | Add-Member -NotePropertyName lastAgentMessage -NotePropertyValue $Message -Force }
    }

    Write-Utf8NoBomAtomic -Path $taskPath -Content (($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    return $document
}
$task = if ($ExecutionRunId -and $WorkspaceLeaseId) {
    $coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
    Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        if (-not (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) {
            throw "Workspace coordinator state is missing for task '$TaskId'."
        }
        $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $activeLease = @($coordinator.leases | Where-Object {
            [string]$_.taskId -eq $TaskId -and
            [string]$_.runId -eq $ExecutionRunId -and
            [string]$_.leaseId -eq $WorkspaceLeaseId -and
            [string]$_.lifecycle -eq 'active'
        } | Select-Object -First 1)
        if (-not $activeLease.Count) {
            throw "Task '$TaskId' does not own active workspace lease '$WorkspaceLeaseId' for run '$ExecutionRunId'."
        }
        Invoke-EcosystemFileLock -LockPath $taskLockPath -TimeoutSeconds 30 -Action $updateTaskState
    }
}
else {
    Invoke-EcosystemFileLock -LockPath $taskLockPath -TimeoutSeconds 30 -Action $updateTaskState
}

$eventType = if ($AgentId) { 'agent-status' } else { 'workflow-status' }
$eventSummary = if ($Message) { $Message } elseif ($AgentId) { "$AgentId is $AgentStatus." } elseif ($Status) { "Workflow is $Status." } else { 'Workflow state updated.' }
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Actor -Type $eventType -Summary $eventSummary -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome
if ($AgentId) {
    $activityLevel = switch ($AgentStatus) {
        'running' { 'progress' }
        'completed' { 'success' }
        'waiting' { 'waiting' }
        'failed' { 'error' }
        'skipped' { 'warning' }
        default { 'info' }
    }
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId $AgentId -Summary $eventSummary -Level $activityLevel -Stage $Stage -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
[pscustomobject]@{ TaskId=$TaskId; Status=[string]$task.status; AgentId=$AgentId; AgentStatus=$AgentStatus; UpdatedAtUtc=$now; Event=$event }
