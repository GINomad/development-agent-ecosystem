[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskRoot,
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $AttemptId,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $LeaseId,
    [Parameter(Mandatory)][string] $AgentId,
    [Parameter(Mandatory)][string] $ConfiguredMode,
    [Parameter(Mandatory)][string] $EffectiveMode,
    [Parameter(Mandatory)][ValidateSet('succeeded','failed')][string] $Status,
    [Parameter(Mandatory)][int] $DurationMs,
    [bool] $QualityObserved = $false,
    [AllowNull()][object] $QualityValue = $null,
    [AllowNull()][string] $QualitySource = $null,
    [bool] $QualityComparable = $false,
    [ValidateSet('passed','failed','not-observed')][string] $ArtifactValidation = 'not-observed',
    [int] $McpCallCount = 0,
    [int] $McpSucceededCallCount = 0,
    [switch] $FallbackUsed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $TaskRoot 'role-metrics.jsonl'
$lockPath = $path + '.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $existing = $line | ConvertFrom-Json } catch { continue }
            if ([string]$existing.attemptId -eq $AttemptId -and [string]$existing.eventType -eq 'role-attempt-completed') {
                return [pscustomobject]@{ Written=$false; Existing=$existing; Path=[IO.Path]::GetFullPath($path) }
            }
        }
    }
    $record = [ordered]@{
        schemaVersion = 2
        metricLevel = 'role'
        eventType = 'role-attempt-completed'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        taskId = $TaskId
        attemptId = $AttemptId
        runId = $RunId
        leaseId = $LeaseId
        agentId = $AgentId
        configuredMode = $ConfiguredMode
        effectiveMode = $EffectiveMode
        mode = $EffectiveMode
        server = if ($EffectiveMode -eq 'mcp') { 'ecosystem-read' } else { 'classic' }
        status = $Status
        durationMs = $DurationMs
        qualityObserved = $QualityObserved
        qualityValue = $QualityValue
        qualitySource = $QualitySource
        qualityComparable = $QualityComparable
        artifactValidation = $ArtifactValidation
        mcpCallCount = $McpCallCount
        mcpSucceededCallCount = $McpSucceededCallCount
        fallbackUsed = [bool]$FallbackUsed
    }
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ Written=$true; Record=[pscustomobject]$record; Path=[IO.Path]::GetFullPath($path) }
}
finally { $lock.Dispose() }
