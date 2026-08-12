[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Summary,
    [ValidateSet('info','progress','success','warning','error','waiting')][string] $Level = 'info',
    [string] $Stage,
    [ValidateLength(0,8000)][string] $Details,
    [ValidateLength(0,100)][string] $Operation,
    [ValidateLength(0,2000)][string] $Target,
    [ValidateRange(0,100)][Nullable[int]] $ProgressPercent,
    [ValidateLength(0,4000)][string] $NextAction,
    [ValidateCount(0,20)][string[]] $Evidence = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { $_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }

function Protect-ActivityText {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $text = $text -replace '(?i)(authorization:\s*bearer\s+)[^\s"'']+', '$1[redacted]'
    return ($text -replace '(?i)((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s"'']+', '$1[redacted]')
}

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
    summary = Protect-ActivityText -Value $Summary.Trim()
    details = if ([string]::IsNullOrWhiteSpace($Details)) { $null } else { Protect-ActivityText -Value $Details.Trim() }
    operation = if ([string]::IsNullOrWhiteSpace($Operation)) { $null } else { Protect-ActivityText -Value $Operation.Trim() }
    target = if ([string]::IsNullOrWhiteSpace($Target)) { $null } else { Protect-ActivityText -Value $Target.Trim() }
    progressPercent = if ($null -eq $ProgressPercent) { $null } else { [int]$ProgressPercent }
    nextAction = if ([string]::IsNullOrWhiteSpace($NextAction)) { $null } else { Protect-ActivityText -Value $NextAction.Trim() }
    evidence = @($Evidence | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 20 | ForEach-Object { Protect-ActivityText -Value $_.Trim() })
}
$activityPath = Join-Path $taskRoot 'agent-activity.jsonl'
$line = ($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($activityPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

[pscustomobject]$record
