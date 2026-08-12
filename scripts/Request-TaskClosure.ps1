[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateLength(5,2000)][string] $Reason,
    [ValidateSet('manual','pr-completed')][string] $Kind = 'manual',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$task.status -eq 'running') { throw 'Stop the workflow before closing the task manually.' }
if ([string]$task.status -eq 'completed') { throw 'The task is already completed. Reopen it before creating another closure.' }

$now = [DateTime]::UtcNow.ToString('o')
$closure = [pscustomobject][ordered]@{
    kind = $Kind
    status = 'knowledge-update-pending'
    reason = $Reason.Trim()
    requestedBy = if ($Kind -eq 'manual') { 'user' } else { 'pipeline_monitor' }
    requestedAtUtc = $now
    completedAtUtc = $null
}
$task | Add-Member -NotePropertyName closure -NotePropertyValue $closure -Force
$task | Add-Member -NotePropertyName status -NotePropertyValue 'queued' -Force
$closureStage = if ($Kind -eq 'manual') { 'manual_close_knowledge_update' } else { 'pr_completed_orchestration' }
$closureLabel = if ($Kind -eq 'manual') { 'Manual closure' } else { 'Completed PR closure' }
$targetAgentId = if ($Kind -eq 'manual') { 'knowledge_keeper' } else { 'orchestrator' }
$task | Add-Member -NotePropertyName currentStage -NotePropertyValue $closureStage -Force
$closureMessage = if ($Kind -eq 'manual') {
    'Manual closure requested. Knowledge Keeper must update verified knowledge and publish the final task summary.'
}
else {
    'Completed PR closure requested. Orchestrator must validate the terminal evidence and route final publication to Knowledge Keeper.'
}
$task | Add-Member -NotePropertyName lastMessage -NotePropertyValue $closureMessage -Force
$task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force
$targetState = [pscustomobject][ordered]@{
    status = 'pending'
    updatedAtUtc = $now
    message = if ($Kind -eq 'manual') { 'Manual closure is waiting for the final knowledge update.' } else { 'Completed PR evidence is waiting for Orchestrator routing.' }
}
$task.agentStatuses | Add-Member -NotePropertyName $targetAgentId -NotePropertyValue $targetState -Force
Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)

$closurePath = Join-Path $taskRoot 'task-closure.json'
Write-Utf8NoBom -Path $closurePath -Content (($closure | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $(if ($Kind -eq 'manual') { 'user' } else { 'pipeline_monitor' }) -Type task-close-requested -Summary "$closureLabel requested: $($closure.reason)" -Artifact $closurePath -Evidence @($Kind) -TargetAgentId $targetAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$instruction = if ($Kind -eq 'manual') {
    "Finalize this task as a manual closure. Reason: $($closure.reason). Update only evidence-backed knowledge, record incomplete delivery work as residual items, and publish task-summary.json."
}
else {
    "The task pull request completed. Reason: $($closure.reason). Validate the persisted terminal pipeline and PR evidence, then route only the final evidence-backed knowledge publication and task-summary.json work to Knowledge Keeper."
}
& (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') -TaskId $TaskId -Text $instruction -Author $(if ($Kind -eq 'manual') { 'user' } else { 'pipeline_monitor' }) -TargetAgentId $targetAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{ TaskId=$TaskId; Status=if ($Kind -eq 'manual') { 'knowledge-update-pending' } else { 'orchestration-pending' }; Kind=$Kind; Reason=$closure.reason; TargetAgentId=$targetAgentId; ClosurePath=$closurePath }
