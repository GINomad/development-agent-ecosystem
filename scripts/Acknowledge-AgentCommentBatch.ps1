[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]] $EventIds,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$batch = & (Join-Path $PSScriptRoot 'Get-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome
$pendingIds = @($batch.eventIds)
$requestedIds = @($EventIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
foreach ($eventId in $requestedIds) {
    if ($eventId -notin $pendingIds) { throw "Comment '$eventId' is not an unacknowledged comment applicable to '$AgentId'." }
    $pendingComment = @($batch.comments | Where-Object { [string]$_.eventId -eq $eventId }) | Select-Object -First 1
    if ($AgentId -eq 'reviewer' -and $pendingComment -and [bool]$pendingComment.requiresResponse) {
        throw "Reviewer cannot acknowledge review question '$([string]$pendingComment.reviewQuestionId)' before persisting an answer."
    }
}
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type user-comment-acknowledged -Summary "$AgentId applied $($requestedIds.Count) comment(s) at one work-block checkpoint." -Evidence $requestedIds -TargetAgentId $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome
[pscustomobject]@{ TaskId=$TaskId; AgentId=$AgentId; Count=$requestedIds.Count; EventIds=$requestedIds; AcknowledgementEventId=[string]$event.eventId }
