[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^REV-[0-9]{3,}$')][string] $FindingId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Reason,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $CreatedBy,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$reviewPath = Join-Path $taskRoot 'review-result.json'
if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw "Review artifact was not found: $reviewPath" }
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$finding = @(@($review.findings) + @($review.agentProcessFindings) | Where-Object { [string]$_.id -eq $FindingId }) | Select-Object -First 1
if (-not $finding) { throw "Finding '$FindingId' does not exist in $reviewPath." }
$verificationPath = Join-Path $taskRoot 'review-verification.json'
if (-not (Test-Path -LiteralPath $verificationPath -PathType Leaf)) { throw 'Independent review verification is required before bypass debt can be created.' }
$verification = Get-Content -LiteralPath $verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'Test-AgentOutcomeArtifact.ps1') -TaskId $TaskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
if ([string]$verification.verificationStatus -ne 'passed') { throw 'Bypass debt is blocked until review coverage and lifecycle verification pass.' }
$findingVerification = @($verification.findingVerifications | Where-Object { [string]$_.findingId -eq $FindingId -and [string]$_.verdict -in @('confirmed','needs-human') }) | Select-Object -First 1
if (-not $findingVerification) { throw "Finding '$FindingId' is not independently verified for a bypass decision." }
$reviewArtifactSha256 = Get-EcosystemFileSha256 -Path $reviewPath

$debtPath = Join-Path $taskRoot 'tech-debt-items.json'
$document = if (Test-Path -LiteralPath $debtPath -PathType Leaf) { Get-Content -LiteralPath $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject][ordered]@{ taskId=$TaskId; items=@() } }
$existing = @($document.items | Where-Object { [string]$_.sourceFindingId -eq $FindingId }) | Select-Object -First 1
if ($existing) {
    $existingReviewSha256 = if ($existing.PSObject.Properties['reviewArtifactSha256']) { [string]$existing.reviewArtifactSha256 } else { '' }
    if ($existingReviewSha256 -eq $reviewArtifactSha256 -and [string]$existing.status -eq 'open') { return $existing }
    $previousBindings = if ($existing.PSObject.Properties['previousReviewBindings']) { @($existing.previousReviewBindings) } else { @() }
    if ($existingReviewSha256 -ne $reviewArtifactSha256) {
        $previousBindings += @([pscustomobject][ordered]@{
            reviewedRevision = if ($existing.PSObject.Properties['reviewedRevision']) { [string]$existing.reviewedRevision } else { 'legacy' }
            reviewArtifactSha256 = if ($existing.PSObject.Properties['reviewArtifactSha256']) { [string]$existing.reviewArtifactSha256 } else { 'legacy' }
            bypassReason = [string]$existing.bypassReason
        })
    }
    $existing | Add-Member -NotePropertyName previousReviewBindings -NotePropertyValue @($previousBindings) -Force
    $existing | Add-Member -NotePropertyName status -NotePropertyValue 'open' -Force
    $existing | Add-Member -NotePropertyName severity -NotePropertyValue ([string]$finding.severity) -Force
    $existing | Add-Member -NotePropertyName category -NotePropertyValue ([string]$finding.category) -Force
    $existing | Add-Member -NotePropertyName reviewArtifact -NotePropertyValue $reviewPath -Force
    $existing | Add-Member -NotePropertyName reviewedRevision -NotePropertyValue ([string]$review.reviewedRevision) -Force
    $existing | Add-Member -NotePropertyName reviewArtifactSha256 -NotePropertyValue $reviewArtifactSha256 -Force
    $existing | Add-Member -NotePropertyName reviewVerificationArtifact -NotePropertyValue $verificationPath -Force
    $existing | Add-Member -NotePropertyName bypassReason -NotePropertyValue $Reason.Trim() -Force
    $existing | Add-Member -NotePropertyName evidence -NotePropertyValue ([string]$finding.evidence) -Force
    $existing | Add-Member -NotePropertyName impact -NotePropertyValue ([string]$finding.impact) -Force
    $existing | Add-Member -NotePropertyName correctionDirection -NotePropertyValue ([string]$finding.correctionDirection) -Force
    $existing | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $temporary = "$debtPath.tmp"
    Write-Utf8NoBom -Path $temporary -Content (($document | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    Move-Item -LiteralPath $temporary -Destination $debtPath -Force
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor review_verifier -Type 'tech-debt-created' -Summary "$([string]$existing.id) was opened and bound to bypassed independently verified Reviewer finding $FindingId at the current review revision. $($existing.bypassReason)" -Artifact $debtPath -Evidence @("review-finding:$FindingId", "review-sha256:$reviewArtifactSha256", "tech-debt-item:$([string]$existing.id)", $reviewPath, $verificationPath) -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return $existing
}

$itemId = 'TD-' + $FindingId
$title = [string]$finding.impact
if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$finding.correctionDirection }
if ([string]::IsNullOrWhiteSpace($title)) { $title = "Reviewer finding $FindingId" }
if ($title.Length -gt 180) { $title = $title.Substring(0, 177) + '...' }
$item = [pscustomobject][ordered]@{
    id=$itemId; sourceFindingId=$FindingId; title=$title; status='open'
    severity=[string]$finding.severity; category=[string]$finding.category
    createdAtUtc=[DateTime]::UtcNow.ToString('o'); createdBy=$CreatedBy
    bypassReason=$Reason.Trim(); reviewArtifact=$reviewPath; reviewVerificationArtifact=$verificationPath
    reviewedRevision=[string]$review.reviewedRevision; reviewArtifactSha256=$reviewArtifactSha256
    evidence=[string]$finding.evidence; impact=[string]$finding.impact
    correctionDirection=[string]$finding.correctionDirection
}
$document.items = @($document.items) + @($item)
$temporary = "$debtPath.tmp"
Write-Utf8NoBom -Path $temporary -Content (($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
Move-Item -LiteralPath $temporary -Destination $debtPath -Force
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor review_verifier -Type 'tech-debt-created' -Summary "$itemId tracks bypassed independently verified Reviewer finding $FindingId. $($item.bypassReason)" -Artifact $debtPath -Evidence @("review-finding:$FindingId", "review-sha256:$reviewArtifactSha256", "tech-debt-item:$itemId", $reviewPath, $verificationPath) -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$item
