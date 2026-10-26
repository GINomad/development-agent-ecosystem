[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskRoot,
    [Parameter(Mandatory)][string] $TaskId,
    [string] $AttemptId,
    [string] $RunId,
    [string] $LeaseId,
    [Parameter(Mandatory)][string] $AgentId,
    [Parameter(Mandatory)][ValidateSet('skill','knowledge','repository-map','artifact','context-pack')][string] $SourceKind,
    [Parameter(Mandatory)][ValidateSet('selected','read','used','reused','rebuilt','full-scan','fallback')][string] $AccessMode,
    [Parameter(Mandatory)][string] $SourceId,
    [string] $SourceLocation,
    [string] $SourceRevision,
    [string] $ContextPackId,
    [string] $RepositoryId,
    [bool] $CacheHit = $false,
    [ValidateSet('observed','declared','verified')][string] $EvidenceKind = 'observed',
    [int] $DurationMs = 0,
    [string] $Status = 'succeeded',
    [string] $Detail,
    [ValidateRange(1, 300)][int] $LockTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$path = Join-Path $TaskRoot 'knowledge-usage.jsonl'
$lockPath = $path + '.lock'
$record = [ordered]@{
        schemaVersion = 1
        metricLevel = 'knowledge'
        eventType = 'knowledge-access'
        eventId = [guid]::NewGuid().ToString('N')
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        taskId = $TaskId
        attemptId = $AttemptId
        runId = $RunId
        leaseId = $LeaseId
        agentId = $AgentId
        sourceKind = $SourceKind
        accessMode = $AccessMode
        sourceId = $SourceId
        sourceLocation = $SourceLocation
        sourceRevision = $SourceRevision
        contextPackId = $ContextPackId
        repositoryId = $RepositoryId
        cacheHit = [bool]$CacheHit
        evidenceKind = $EvidenceKind
        durationMs = $DurationMs
        status = $Status
        detail = $Detail
}
try {
    Invoke-EcosystemFileLock -LockPath $lockPath -TimeoutSeconds $LockTimeoutSeconds -Action {
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]$record
    }
}
catch {
    $exception = $_.Exception
    $isLockContention = $false
    while ($exception) {
        if ($exception -is [IO.IOException] -and $exception.Message -match '(?i)(lock|used by another process|sharing violation)') {
            $isLockContention = $true
            break
        }
        $exception = $exception.InnerException
    }
    if (-not $isLockContention) { throw }

    Write-Verbose "Knowledge access metric was deferred because '$lockPath' remained exclusively locked for $LockTimeoutSeconds second(s)."
    [pscustomobject]([ordered]@{
        schemaVersion = 1
        metricLevel = 'knowledge'
        eventType = 'knowledge-access'
        eventId = $record.eventId
        timestampUtc = $record.timestampUtc
        taskId = $TaskId
        agentId = $AgentId
        sourceKind = $SourceKind
        accessMode = $AccessMode
        sourceId = $SourceId
        status = 'deferred-lock-contention'
        detail = "Knowledge metric was not persisted because its exclusive lock remained unavailable for $LockTimeoutSeconds second(s)."
    })
}
