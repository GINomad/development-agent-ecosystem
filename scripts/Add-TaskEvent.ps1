[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $Actor,
    [Parameter(Mandatory)][ValidateSet('task-created','workflow-status','agent-status','user-comment','user-comment-acknowledged','context-issued','agent-result','question-opened','question-resolved','scope-held','scope-released','review-decision','external-action','knowledge-updated')][string] $Type,
    [Parameter(Mandatory)][string] $Summary,
    [string] $Artifact,
    [string[]] $Evidence = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
$event = [ordered]@{
    eventId = [guid]::NewGuid().ToString('N')
    taskId = $TaskId
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    actor = $Actor
    type = $Type
    summary = $Summary
    artifact = if ($Artifact) { $Artifact } else { $null }
    evidence = @($Evidence)
}
$line = ($event | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($ledgerPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
[pscustomobject]$event
