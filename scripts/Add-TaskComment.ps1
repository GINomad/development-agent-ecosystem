[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Text,
    [string] $Author = 'user',
    [ValidatePattern('^[a-fA-F0-9]{32}$')][string] $QuestionId,
    [ValidateSet('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor','health_check')][string] $TargetAgentId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$commentText = $Text.Trim()
if (-not $commentText) { throw 'Comment cannot be empty.' }
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$question = $null
if ($QuestionId) {
    $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
    $events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) } else { @() }
    $question = @($events | Where-Object { $_.type -eq 'question-opened' -and $_.eventId -eq $QuestionId }) | Select-Object -First 1
    if (-not $question) { throw "Open question '$QuestionId' was not found." }
    $alreadyResolved = @($events | Where-Object { $_.type -eq 'question-resolved' -and @($_.evidence) -contains $QuestionId }).Count -gt 0
    if ($alreadyResolved) { throw "Question '$QuestionId' is already resolved." }
    $questionAgentId = [string]$question.actor
    if ($TargetAgentId -and $TargetAgentId -ne $questionAgentId) { throw "Question '$QuestionId' belongs to agent '$questionAgentId', not '$TargetAgentId'." }
    $TargetAgentId = $questionAgentId
}
if ($TargetAgentId -and -not @($config.agents | Where-Object { [string]$_.id -eq $TargetAgentId }).Count) { throw "Unknown target agent '$TargetAgentId'." }

$eventParameters = @{ TaskId=$TaskId; Actor=$Author; Type='user-comment'; Summary=$commentText; Artifact=$taskPath; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
if ($TargetAgentId) { $eventParameters.TargetAgentId = $TargetAgentId }
if ($QuestionId) { $eventParameters.Evidence = @($QuestionId) }
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') @eventParameters
$resolvedEvent = $null
if ($QuestionId) {
    $resolvedEvent = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Author -Type 'question-resolved' -Summary "User answered question from $([string]$question.actor): $([string]$question.summary)" -Artifact $taskPath -Evidence @($QuestionId, [string]$event.eventId) -ConfigPath $ConfigPath -CodexHome $CodexHome
}
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([string]$event.timestampUtc) -Force
$task | Add-Member -NotePropertyName lastCommentAtUtc -NotePropertyValue ([string]$event.timestampUtc) -Force
$task | Add-Member -NotePropertyName hasUnreadUserComments -NotePropertyValue $true -Force
if ($QuestionId) {
    $task | Add-Member -NotePropertyName status -NotePropertyValue 'interrupted' -Force
    $task | Add-Member -NotePropertyName currentStage -NotePropertyValue 'input_received' -Force
    $task | Add-Member -NotePropertyName lastMessage -NotePropertyValue 'A user answer is ready. Resume the workflow to continue from the input gate.' -Force
}
else {
    $commentDestination = if ($TargetAgentId) { "agent '$TargetAgentId'" } else { 'the workflow' }
    $task | Add-Member -NotePropertyName lastMessage -NotePropertyValue "A user comment for $commentDestination is queued for the active agent's next end-of-block checkpoint; no restart is required while it is running." -Force
}
Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

[pscustomobject]@{ TaskId=$TaskId; CommentId=[string]$event.eventId; QuestionId=if ($QuestionId) { $QuestionId } else { $null }; TargetAgentId=if ($TargetAgentId) { $TargetAgentId } else { $null }; ResolvedEventId=if ($resolvedEvent) { [string]$resolvedEvent.eventId } else { $null }; TimestampUtc=[string]$event.timestampUtc; Text=$commentText }
