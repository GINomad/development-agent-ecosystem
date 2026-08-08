[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Text,
    [string] $Author = 'user',
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

$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Author -Type 'user-comment' -Summary $commentText -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([string]$event.timestampUtc) -Force
$task | Add-Member -NotePropertyName lastCommentAtUtc -NotePropertyValue ([string]$event.timestampUtc) -Force
$task | Add-Member -NotePropertyName hasUnreadUserComments -NotePropertyValue $true -Force
$task | Add-Member -NotePropertyName lastMessage -NotePropertyValue 'A user comment is waiting for the workflow checkpoint.' -Force
Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

[pscustomobject]@{ TaskId=$TaskId; CommentId=[string]$event.eventId; TimestampUtc=[string]$event.timestampUtc; Text=$commentText }

