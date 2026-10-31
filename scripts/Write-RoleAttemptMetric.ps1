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
    [switch] $FallbackUsed,
    [string[]] $FallbackReasons = @(),
    [ValidateRange(1,300)][int] $LockTimeoutSeconds = 30,
    [AllowNull()][string] $ExecutionBundleManifestPath = $null,
    [AllowNull()][string] $ExecutionBundleManifestSha256 = $null,
    [AllowNull()][string] $ExecutionBundleFingerprint = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $TaskRoot 'role-metrics.jsonl'
$lockPath = $path + '.lock'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ExecutionBundleManifestPath) -or [string]::IsNullOrWhiteSpace($ExecutionBundleManifestSha256)) {
    $contextPath = Join-Path $TaskRoot ('execution-context-' + $RunId + '.json')
    if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
        try {
            $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($ExecutionBundleManifestPath) -and $context.PSObject.Properties['launchBundlePath']) { $ExecutionBundleManifestPath = [string]$context.launchBundlePath }
            $expectedManifestPath = [IO.Path]::GetFullPath((Join-Path $TaskRoot ("execution-bundles\$RunId\manifest.json")))
            if ($ExecutionBundleManifestPath -and [IO.Path]::GetFullPath($ExecutionBundleManifestPath) -eq $expectedManifestPath -and (Test-Path -LiteralPath $expectedManifestPath -PathType Leaf)) {
                if ([string]::IsNullOrWhiteSpace($ExecutionBundleManifestSha256)) { $ExecutionBundleManifestSha256 = Get-EcosystemFileSha256 -Path $expectedManifestPath }
                if ($context.PSObject.Properties['launchBundleFingerprint']) { $ExecutionBundleFingerprint = [string]$context.launchBundleFingerprint }
            }
        } catch { }
    }
}
try {
Invoke-EcosystemFileLock -LockPath $lockPath -TimeoutSeconds $LockTimeoutSeconds -Action {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $existing = $line | ConvertFrom-Json } catch { continue }
            if (-not $existing.PSObject.Properties['taskId'] -or -not $existing.PSObject.Properties['runId'] -or -not $existing.PSObject.Properties['attemptId'] -or -not $existing.PSObject.Properties['eventType']) { continue }
            if ([string]$existing.taskId -eq $TaskId -and [string]$existing.runId -eq $RunId -and [string]$existing.attemptId -eq $AttemptId -and [string]$existing.eventType -eq 'role-attempt-completed') {
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
        server = if ($EffectiveMode -in @('mcp','mcp-with-tool-fallback')) { 'ecosystem-read' } else { 'classic' }
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
        fallbackReasons = @($FallbackReasons)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionBundleManifestPath)) { $record.executionBundleManifestPath = $ExecutionBundleManifestPath }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionBundleManifestSha256)) { $record.executionBundleManifestSha256 = $ExecutionBundleManifestSha256 }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionBundleFingerprint)) { $record.executionBundleFingerprint = $ExecutionBundleFingerprint }
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ Written=$true; Record=[pscustomobject]$record; Path=[IO.Path]::GetFullPath($path) }
}
}
catch [IO.IOException] {
    # Telemetry must not turn a completed role into a failed workflow when a peer
    # holds the metric lock beyond the bounded retry window.
    [pscustomobject]@{ Written=$false; Deferred=$true; Reason='lock-contention'; Path=[IO.Path]::GetFullPath($path) }
}
