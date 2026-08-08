[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $RepositoryId,
    [int] $PullRequestId,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $Author = $env:USERNAME,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Reviewer note cannot be empty.' }
if ($Text.Length -gt 8000) { throw 'Reviewer note cannot exceed 8000 characters.' }
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.repositories | Where-Object { $_.id -eq $RepositoryId }).Count) { throw "Unknown repository '$RepositoryId'." }
$notesRoot = Resolve-EcosystemPath -Value ([string]$config.review.userNotesRoot) -Config $config -CodexHome $CodexHome
$scope = if ($PullRequestId -gt 0) { "pr-$PullRequestId" } elseif ($TaskId) { "task-$TaskId" } else { 'general' }
$path = Join-Path $notesRoot "$RepositoryId\$scope.jsonl"
New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
$entry = [ordered]@{
    id = [guid]::NewGuid().ToString('N')
    repositoryId = $RepositoryId
    pullRequestId = if ($PullRequestId -gt 0) { $PullRequestId } else { $null }
    taskId = if ($TaskId) { $TaskId } else { $null }
    author = $Author
    createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    text = $Text
}
$line = ($entry | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
if ($TaskId) {
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Author -Type 'agent-result' -Summary 'User added a local reviewer note.' -Artifact $path -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
[pscustomobject]$entry

