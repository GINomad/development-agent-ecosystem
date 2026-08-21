[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string] $ReviewQuestionId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Answer,
    [string[]] $Evidence = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$events = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
$question = @($events | Where-Object { [string]$_.eventId -eq $ReviewQuestionId -and [string]$_.type -eq 'review-question-opened' }) | Select-Object -First 1
if (-not $question) { throw "Review question '$ReviewQuestionId' was not found." }
if (@($events | Where-Object { [string]$_.type -eq 'review-question-answered' -and @($_.evidence) -contains $ReviewQuestionId }).Count) { throw "Review question '$ReviewQuestionId' is already answered." }
$sourceCommentId = @($question.evidence | Select-Object -First 1)[0]
$sourceComment = @($events | Where-Object { [string]$_.eventId -eq [string]$sourceCommentId -and [string]$_.type -eq 'user-comment' -and [string]$_.targetAgentId -eq 'reviewer' }) | Select-Object -First 1
if (-not $sourceComment) { throw "Review question '$ReviewQuestionId' does not reference a valid Reviewer-targeted user comment." }
$answerText = $Answer.Trim()
if (-not $answerText) { throw 'Reviewer answer cannot be empty.' }
$answerEvidence = @($ReviewQuestionId, [string]$sourceComment.eventId) + @($Evidence | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor reviewer -Type 'review-question-answered' -Summary $answerText -Artifact $ledgerPath -Evidence $answerEvidence -ConfigPath $ConfigPath -CodexHome $CodexHome
[pscustomobject]@{ TaskId=$TaskId; ReviewQuestionId=$ReviewQuestionId; SourceCommentId=[string]$sourceComment.eventId; AnswerEventId=[string]$event.eventId; Answer=$answerText }
