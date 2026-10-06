[CmdletBinding()]
param([Parameter(Mandatory)][string] $ReviewPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) { throw "Review artifact was not found: $ReviewPath" }
$review = Get-Content -LiteralPath $ReviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $review.PSObject.Properties['reviewScope'] -or -not $review.PSObject.Properties['reviewCoverage'] -or -not $review.PSObject.Properties['findingLifecycle']) { throw 'Review artifact is missing reviewScope, reviewCoverage, or findingLifecycle.' }
[pscustomobject][ordered]@{
    reviewedRevision = [string]$review.reviewedRevision
    reviewScope = $review.reviewScope
    coverage = @($review.reviewCoverage | ForEach-Object { [pscustomobject][ordered]@{ dimension=[string]$_.dimension; status=[string]$_.status; evidence=@($_.evidence); falsificationAttempts=@($_.falsificationAttempts) } })
    activeFindingIds = @($review.findings | ForEach-Object { [string]$_.id })
    lifecycle = @($review.findingLifecycle | ForEach-Object { [pscustomobject][ordered]@{ findingId=[string]$_.findingId; status=[string]$_.status; firstSeenRevision=[string]$_.firstSeenRevision; lastObservedRevision=[string]$_.lastObservedRevision } })
}
