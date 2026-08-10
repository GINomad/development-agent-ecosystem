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
    requestedBy = 'user'
    requestedAtUtc = $now
    completedAtUtc = $null
}
$task | Add-Member -NotePropertyName closure -NotePropertyValue $closure -Force
$task | Add-Member -NotePropertyName status -NotePropertyValue 'queued' -Force
$closureStage = if ($Kind -eq 'manual') { 'manual_close_knowledge_update' } else { 'pr_completed_knowledge_update' }
$closureLabel = if ($Kind -eq 'manual') { 'Manual closure' } else { 'Completed PR closure' }
$task | Add-Member -NotePropertyName currentStage -NotePropertyValue $closureStage -Force
$task | Add-Member -NotePropertyName lastMessage -NotePropertyValue "$closureLabel requested. Knowledge Keeper must update verified knowledge and publish the final task summary." -Force
$task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force
$keeperState = [pscustomobject][ordered]@{ status='pending'; updatedAtUtc=$now; message='Manual closure is waiting for the final knowledge update.' }
$task.agentStatuses | Add-Member -NotePropertyName knowledge_keeper -NotePropertyValue $keeperState -Force
Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)

$closurePath = Join-Path $taskRoot 'task-closure.json'
Write-Utf8NoBom -Path $closurePath -Content (($closure | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $(if ($Kind -eq 'manual') { 'user' } else { 'pipeline_monitor' }) -Type task-close-requested -Summary "$closureLabel requested: $($closure.reason)" -Artifact $closurePath -Evidence @($Kind) -TargetAgentId knowledge_keeper -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$instruction = if ($Kind -eq 'manual') { "Finalize this task as a manual closure. Reason: $($closure.reason). Update only evidence-backed knowledge, record incomplete delivery work as residual items, and publish task-summary.json." } else { "The task pull request completed. Reason: $($closure.reason). Update evidence-backed knowledge, capture the final implementation and review decisions, and publish task-summary.json." }
& (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') -TaskId $TaskId -Text $instruction -Author $(if ($Kind -eq 'manual') { 'user' } else { 'pipeline_monitor' }) -TargetAgentId knowledge_keeper -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{ TaskId=$TaskId; Status='knowledge-update-pending'; Kind=$Kind; Reason=$closure.reason; ClosurePath=$closurePath }
