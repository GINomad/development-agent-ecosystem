[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Summary,
    [ValidateSet('info','progress','success','warning','error','waiting')][string] $Level = 'info',
    [string] $Stage,
    [ValidateLength(0,8000)][string] $Details,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { $_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$record = [ordered]@{
    type = 'agent-activity'
    activityId = [guid]::NewGuid().ToString('N')
    taskId = $TaskId
    agentId = $AgentId
    timestampUtc = [DateTime]::UtcNow.ToString('o')
    level = $Level
    stage = if ($Stage) { $Stage } else { $null }
    summary = $Summary.Trim()
    details = if ([string]::IsNullOrWhiteSpace($Details)) { $null } else { $Details.Trim() }
}
$activityPath = Join-Path $taskRoot 'agent-activity.jsonl'
$line = ($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($activityPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

[pscustomobject]$record
