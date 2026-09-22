[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskRoot,
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $AttemptId,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $AgentId,
    [Parameter(Mandatory)][ValidateSet('succeeded','failed')][string] $Status,
    [Parameter(Mandatory)][int] $DurationMs,
    [AllowNull()][string] $ErrorClass = $null
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$record = [ordered]@{schemaVersion=1;metricLevel='continuation';eventType='continuation-completed';timestampUtc=[DateTime]::UtcNow.ToString('o');taskId=$TaskId;attemptId=$AttemptId;runId=$RunId;agentId=$AgentId;status=$Status;durationMs=$DurationMs;errorClass=$ErrorClass}
$path = Join-Path $TaskRoot 'continuation-metrics.jsonl'
$lock = [IO.File]::Open(($path+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { [IO.File]::AppendAllText($path,(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false))) }
finally { $lock.Dispose() }
[pscustomobject]$record
