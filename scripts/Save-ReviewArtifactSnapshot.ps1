[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = [IO.Path]::GetFullPath((Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"))
$reviewPath = Join-Path $taskRoot 'review-result.json'
if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw 'review-result.json is required before a review snapshot can be saved.' }
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$review.taskId -ne $TaskId) { throw 'review-result.json belongs to another task.' }

$reviewSha256 = Get-EcosystemFileSha256 -Path $reviewPath
$historyRoot = [IO.Path]::GetFullPath((Join-Path $taskRoot 'review-history'))
$taskPrefix = $taskRoot.TrimEnd('\') + '\'
if (-not $historyRoot.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Review history path escaped the task root.' }
$snapshotName = "review-$reviewSha256.json"
$snapshotPath = Join-Path $historyRoot $snapshotName
$indexPath = Join-Path $taskRoot 'review-history-index.json'

$result = Invoke-EcosystemFileLock -LockPath ($indexPath + '.lock') -TimeoutSeconds 30 -Action {
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        Copy-Item -LiteralPath $reviewPath -Destination $snapshotPath
    }
    $snapshotSha256 = Get-EcosystemFileSha256 -Path $snapshotPath
    if ($snapshotSha256 -ne $reviewSha256) { throw 'Persisted review snapshot does not match review-result.json.' }

    $index = if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        [pscustomobject][ordered]@{ schemaVersion='1.0.0'; taskId=$TaskId; updatedAtUtc=$null; snapshots=@() }
    }
    if ([string]$index.taskId -ne $TaskId) { throw 'review-history-index.json belongs to another task.' }
    $entries = @($index.snapshots)
    $existing = @($entries | Where-Object { [string]$_.sha256 -eq $reviewSha256 }) | Select-Object -First 1
    if (-not $existing) {
        $existing = [pscustomobject][ordered]@{
            reviewedRevision = [string]$review.reviewedRevision
            requirementsRevision = [string]$review.requirementsRevision
            sha256 = $reviewSha256
            relativePath = "review-history/$snapshotName"
            capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $entries = @($entries) + @($existing)
    }
    $index.snapshots = @($entries)
    $index.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-Utf8NoBomAtomic -Path $indexPath -Content (($index | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $existing
}

[pscustomobject][ordered]@{
    TaskId = $TaskId
    ReviewedRevision = [string]$review.reviewedRevision
    ReviewSha256 = $reviewSha256
    SnapshotPath = $snapshotPath
    IndexPath = $indexPath
    CapturedAtUtc = [string]$result.capturedAtUtc
}
