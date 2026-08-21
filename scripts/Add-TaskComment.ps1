[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Text,
    [string] $Author = 'user',
    [ValidatePattern('^[a-fA-F0-9]{32}$')][string] $QuestionId,
    [ValidatePattern('^[A-Za-z0-9._:-]+$')][string] $ReviewFindingId,
    [ValidatePattern('^[a-z][a-z0-9_]*$')][string] $TargetAgentId,
    [ValidateSet('instruction','review-question')][string] $CommentKind = 'instruction',
    [ValidatePattern('^[a-fA-F0-9]{32}$')][string] $ParentReviewQuestionId,
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
elseif (-not $TargetAgentId -and [bool]$config.workflow.orchestration.enabled -and [bool]$config.workflow.orchestration.routeUntargetedComments) {
    $TargetAgentId = [string]$config.workflow.orchestration.agentId
}
if ($TargetAgentId -and -not @($config.agents | Where-Object { [string]$_.id -eq $TargetAgentId }).Count) { throw "Unknown target agent '$TargetAgentId'." }
if ($CommentKind -eq 'review-question') {
    if ($TargetAgentId -ne 'reviewer') { throw 'A review question must target Reviewer.' }
    if (-not $commentText.StartsWith('[Task diff line comment]', [StringComparison]::Ordinal)) { throw 'A review question must include selected task-diff line context.' }
    if ($ParentReviewQuestionId) {
        $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
        $reviewEvents = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) } else { @() }
        $parentQuestion = @($reviewEvents | Where-Object { $_.type -eq 'review-question-opened' -and $_.eventId -eq $ParentReviewQuestionId }) | Select-Object -First 1
        if (-not $parentQuestion) { throw "Parent Reviewer question '$ParentReviewQuestionId' was not found." }
        $parentAnswer = @($reviewEvents | Where-Object { $_.type -eq 'review-question-answered' -and @($_.evidence) -contains $ParentReviewQuestionId }) | Select-Object -Last 1
        if (-not $parentAnswer) { throw "Parent Reviewer question '$ParentReviewQuestionId' has no answer to reply to." }
    }
}
elseif ($ParentReviewQuestionId) {
    throw 'ParentReviewQuestionId is valid only for a Reviewer question.'
}

$eventParameters = @{ TaskId=$TaskId; Actor=$Author; Type='user-comment'; Summary=$commentText; Artifact=$taskPath; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
if ($TargetAgentId) { $eventParameters.TargetAgentId = $TargetAgentId }
$commentEvidence = [Collections.Generic.List[string]]::new()
if ($QuestionId) { $commentEvidence.Add($QuestionId) }
if ($ReviewFindingId) { $commentEvidence.Add("review-finding:$ReviewFindingId") }
if ($ParentReviewQuestionId) { $commentEvidence.Add("parent-review-question:$ParentReviewQuestionId") }
if ($commentEvidence.Count) { $eventParameters.Evidence = @($commentEvidence) }
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') @eventParameters
$reviewQuestionEvent = $null
if ($CommentKind -eq 'review-question') {
    $reviewQuestionEvidence = [Collections.Generic.List[string]]::new()
    $reviewQuestionEvidence.Add([string]$event.eventId)
    if ($ParentReviewQuestionId) {
        $reviewQuestionEvidence.Add("parent-review-question:$ParentReviewQuestionId")
        $reviewQuestionEvidence.Add("parent-review-answer:$([string]$parentAnswer.eventId)")
    }
    $reviewQuestionSummary = if ($ParentReviewQuestionId) { 'A follow-up line-level question is waiting for a read-only Reviewer answer.' } else { 'A line-level question is waiting for a read-only Reviewer answer.' }
    $reviewQuestionEvent = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Author -Type 'review-question-opened' -Summary $reviewQuestionSummary -Artifact $taskPath -Evidence @($reviewQuestionEvidence) -TargetAgentId reviewer -ConfigPath $ConfigPath -CodexHome $CodexHome
}
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
    $commentDestination = if ($TargetAgentId -eq [string]$config.workflow.orchestration.agentId) { 'Orchestrator classification' } elseif ($TargetAgentId) { "agent '$TargetAgentId'" } else { 'the workflow' }
    $task | Add-Member -NotePropertyName lastMessage -NotePropertyValue "A user comment for $commentDestination is queued for the next end-of-block checkpoint; no restart is required while the workflow is running." -Force
}
Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

[pscustomobject]@{ TaskId=$TaskId; CommentId=[string]$event.eventId; CommentKind=$CommentKind; ReviewQuestionId=if ($reviewQuestionEvent) { [string]$reviewQuestionEvent.eventId } else { $null }; ParentReviewQuestionId=if ($ParentReviewQuestionId) { $ParentReviewQuestionId } else { $null }; QuestionId=if ($QuestionId) { $QuestionId } else { $null }; ReviewFindingId=if ($ReviewFindingId) { $ReviewFindingId } else { $null }; TargetAgentId=if ($TargetAgentId) { $TargetAgentId } else { $null }; RoutingStatus=if ($TargetAgentId -eq [string]$config.workflow.orchestration.agentId -and -not $QuestionId) { 'pending-orchestrator' } else { 'direct' }; ResolvedEventId=if ($resolvedEvent) { [string]$resolvedEvent.eventId } else { $null }; TimestampUtc=[string]$event.timestampUtc; Text=$commentText }
