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
    [string] $Detail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$path = Join-Path $TaskRoot 'knowledge-usage.jsonl'
$lockPath = $path + '.lock'
Invoke-EcosystemFileLock -LockPath $lockPath -TimeoutSeconds 30 -Action {
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
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]$record
}
