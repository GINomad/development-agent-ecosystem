[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][string] $ArtifactName,
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $TaskRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CountPairs {
    param([AllowNull()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    @([regex]::Matches($Text, '(?i)\b(?<passed>\d+)\s*/\s*(?<total>\d+)\b') | ForEach-Object {
        [pscustomobject]@{ Passed = [int]$_.Groups['passed'].Value; Total = [int]$_.Groups['total'].Value }
    })
}

function ConvertTo-CountValue {
    param([Parameter(Mandatory)][string] $Token)
    $words = @{ zero=0; one=1; two=2; three=3; four=4; five=5; six=6; seven=7; eight=8; nine=9; ten=10 }
    $normalized = $Token.ToLowerInvariant()
    if ($words.ContainsKey($normalized)) { return [int]$words[$normalized] }
    [int]$normalized
}

function Get-AheadCounts {
    param([AllowNull()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    @([regex]::Matches($Text, '(?i)\b(?<count>zero|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+local\s+commits?\s+ahead\b') | ForEach-Object {
        ConvertTo-CountValue -Token $_.Groups['count'].Value
    })
}

function Invoke-GitReadOnly {
    param([Parameter(Mandatory)][string] $Workspace, [Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& git -C $Workspace @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Outcome validation git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    @($output | ForEach-Object { [string]$_ })
}

function Assert-RequiredProperties {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)][string[]] $Names,
        [Parameter(Mandatory)][string] $Label
    )
    foreach ($name in $Names) {
        if (-not $Document.PSObject.Properties[$name]) { throw "$Label is missing '$name'." }
    }
}

function Test-NonEmptyStringArray {
    param($Value)
    $items = @($Value | Where-Object { $null -ne $_ })
    return $items.Count -gt 0 -and @($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0
}

$reviewDimensions = @('requirements','correctness','security','regression','testing','maintainability','performance','concurrency','configuration-deployment','documentation')

if ($ArtifactName -eq 'review-result.json') {
    if ($AgentId -ne 'reviewer') { throw 'Only Reviewer may publish review-result.json.' }
    $review = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-RequiredProperties -Document $review -Names @('taskId','reviewedRevision','requirementsRevision','requirementTraceability','reviewCoverage','findings','heldScopeViolations','agentProcessFindings','findingLifecycle','summary') -Label 'review-result.json'
    if ([string]$review.taskId -ne $TaskId) { throw "review-result.json must identify task '$TaskId'." }
    if ([string]::IsNullOrWhiteSpace([string]$review.reviewedRevision) -or [string]::IsNullOrWhiteSpace([string]$review.requirementsRevision)) { throw 'Review revisions must be non-empty.' }
    if (-not @($review.requirementTraceability).Count) { throw 'review-result.json requires at least one requirementTraceability entry.' }

    $coverage = @($review.reviewCoverage | Where-Object { $null -ne $_ })
    $coverageDimensions = @($coverage | ForEach-Object { [string]$_.dimension })
    if ($coverage.Count -ne $reviewDimensions.Count -or @($coverageDimensions | Select-Object -Unique).Count -ne $reviewDimensions.Count -or @($reviewDimensions | Where-Object { $_ -notin $coverageDimensions }).Count) {
        throw 'reviewCoverage must contain every configured review dimension exactly once.'
    }
    foreach ($entry in $coverage) {
        Assert-RequiredProperties -Document $entry -Names @('dimension','status','evidence','notes') -Label "reviewCoverage '$([string]$entry.dimension)'"
        if ([string]$entry.status -notin @('covered','not-applicable','blocked') -or -not (Test-NonEmptyStringArray -Value $entry.evidence) -or [string]::IsNullOrWhiteSpace([string]$entry.notes)) {
            throw "reviewCoverage '$([string]$entry.dimension)' lacks a supported status, evidence, or notes."
        }
    }

    $productFindings = @($review.findings | Where-Object { $null -ne $_ })
    $processFindings = @($review.agentProcessFindings | Where-Object { $null -ne $_ })
    $activeFindings = @($productFindings) + @($processFindings)
    $activeIds = @($activeFindings | ForEach-Object { [string]$_.id })
    if (@($activeIds | Where-Object { $_ -notmatch '^REV-[0-9]{3,}$' }).Count -or @($activeIds | Select-Object -Unique).Count -ne $activeIds.Count) {
        throw 'Active Reviewer finding IDs must be valid and unique across product and agent-process findings.'
    }
    foreach ($finding in $activeFindings) {
        Assert-RequiredProperties -Document $finding -Names @('id','severity','category','location','evidence','impact','correctionDirection','decisionStatus') -Label "finding '$([string]$finding.id)'"
        if ([string]$finding.decisionStatus -ne 'proposed') { throw "Finding '$([string]$finding.id)' must remain proposed." }
    }

    $currentReviewSha256 = Get-EcosystemFileSha256 -Path $Path
    $openDebtItems = @()
    $openDebtIds = @()
    $techDebtPath = Join-Path $TaskRoot 'tech-debt-items.json'
    if (Test-Path -LiteralPath $techDebtPath -PathType Leaf) {
        $techDebt = Get-Content -LiteralPath $techDebtPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$techDebt.taskId -ne $TaskId) { throw 'tech-debt-items.json belongs to another task.' }
        $openDebtItems = @($techDebt.items | Where-Object { [string]$_.status -eq 'open' })
        $openDebtIds = @($openDebtItems | ForEach-Object { [string]$_.sourceFindingId } | Select-Object -Unique)
        $priorBypassDebtIds = @($openDebtItems | Where-Object { -not $_.PSObject.Properties['reviewArtifactSha256'] -or [string]$_.reviewArtifactSha256 -ne $currentReviewSha256 } | ForEach-Object { [string]$_.sourceFindingId } | Select-Object -Unique)
        $incorrectlyActiveDebtIds = @($activeIds | Where-Object { $_ -in $priorBypassDebtIds })
        if ($incorrectlyActiveDebtIds.Count) { throw "Open bypass debt from a prior review must be omitted from active findings while remaining in findingLifecycle: $($incorrectlyActiveDebtIds -join ', ')." }
    }
    $currentOutstandingIds = @(@($activeIds) + @($openDebtIds))
    $currentOutstandingIds = @($currentOutstandingIds | Select-Object -Unique)

    $lifecycle = @($review.findingLifecycle | Where-Object { $null -ne $_ })
    $lifecycleIds = @($lifecycle | ForEach-Object { [string]$_.findingId })
    if (@($lifecycleIds | Where-Object { $_ -notmatch '^REV-[0-9]{3,}$' }).Count -or @($lifecycleIds | Select-Object -Unique).Count -ne $lifecycleIds.Count) { throw 'findingLifecycle IDs must be valid and unique.' }
    foreach ($record in $lifecycle) {
        Assert-RequiredProperties -Document $record -Names @('findingId','status','firstSeenRevision','lastObservedRevision','evidence') -Label "findingLifecycle '$([string]$record.findingId)'"
        $recordId = [string]$record.findingId
        $recordStatus = [string]$record.status
        if ($recordStatus -notin @('new','unchanged','resolved','regressed')) { throw "findingLifecycle '$recordId' has an unsupported status." }
        if ([string]::IsNullOrWhiteSpace([string]$record.firstSeenRevision) -or [string]::IsNullOrWhiteSpace([string]$record.lastObservedRevision) -or [string]::IsNullOrWhiteSpace([string]$record.evidence)) { throw "findingLifecycle '$recordId' requires first-seen, last-observed, and evidence values." }
        if ($recordStatus -eq 'new' -and [string]$record.firstSeenRevision -ne [string]$review.reviewedRevision) { throw "New lifecycle '$recordId' must first appear at the current reviewed revision." }
        if ($recordStatus -eq 'resolved') {
            if ($recordId -in $currentOutstandingIds -or -not $record.PSObject.Properties['resolvedRevision'] -or [string]::IsNullOrWhiteSpace([string]$record.resolvedRevision)) { throw "Resolved lifecycle '$recordId' must have neither an active finding nor open review debt and must identify its resolved revision." }
        }
        else {
            if ($recordId -notin $currentOutstandingIds) { throw "Outstanding lifecycle '$recordId' has neither a matching current finding nor open review debt." }
            if ([string]$record.lastObservedRevision -ne [string]$review.reviewedRevision) { throw "Outstanding lifecycle '$recordId' must be observed at the reviewed revision." }
        }
        if ($recordStatus -eq 'regressed' -and (-not $record.PSObject.Properties['previousResolutionRevision'] -or [string]::IsNullOrWhiteSpace([string]$record.previousResolutionRevision))) {
            throw "Regressed lifecycle '$recordId' must identify its previous resolution revision."
        }
    }
    foreach ($findingId in $currentOutstandingIds) {
        if (@($lifecycle | Where-Object { [string]$_.findingId -eq $findingId -and [string]$_.status -ne 'resolved' }).Count -ne 1) {
            throw "Active finding or open review debt '$findingId' requires exactly one non-resolved lifecycle record."
        }
    }

    $currentLifecycleById = @{}
    foreach ($record in $lifecycle) { $currentLifecycleById[[string]$record.findingId] = $record }
    $historyIndexPath = Join-Path $TaskRoot 'review-history-index.json'
    $priorReview = $null
    if (Test-Path -LiteralPath $historyIndexPath -PathType Leaf) {
        $historyIndex = Get-Content -LiteralPath $historyIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$historyIndex.taskId -ne $TaskId) { throw 'review-history-index.json belongs to another task.' }
        $currentSha256 = $currentReviewSha256
        $priorSnapshot = @($historyIndex.snapshots | Where-Object { [string]$_.sha256 -ne $currentSha256 } | Sort-Object { [DateTime]$_.capturedAtUtc } -Descending) | Select-Object -First 1
        if ($priorSnapshot) {
            $priorPath = [IO.Path]::GetFullPath((Join-Path $TaskRoot ([string]$priorSnapshot.relativePath).Replace('/', '\')))
            $historyPrefix = [IO.Path]::GetFullPath((Join-Path $TaskRoot 'review-history')).TrimEnd('\') + '\'
            if (-not $priorPath.StartsWith($historyPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $priorPath -PathType Leaf)) { throw 'Prior review snapshot path is invalid or missing.' }
            if ((Get-EcosystemFileSha256 -Path $priorPath) -ne [string]$priorSnapshot.sha256) { throw 'Prior review snapshot hash does not match its history index.' }
            $priorReview = Get-Content -LiteralPath $priorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    if ($priorReview) {
        $priorLifecycleById = @{}
        foreach ($record in @($priorReview.findingLifecycle)) { $priorLifecycleById[[string]$record.findingId] = $record }
        $priorOutstandingIds = @($priorReview.findingLifecycle | Where-Object { [string]$_.status -ne 'resolved' } | ForEach-Object { [string]$_.findingId })
        foreach ($findingId in $currentOutstandingIds) {
            $record = $currentLifecycleById[$findingId]
            if ($findingId -in $priorOutstandingIds) {
                $priorRecord = $priorLifecycleById[$findingId]
                if ([string]$record.status -ne 'unchanged') { throw "Finding '$findingId' was outstanding previously and must be marked unchanged." }
                if ([string]$record.firstSeenRevision -ne [string]$priorRecord.firstSeenRevision) { throw "Finding '$findingId' must preserve its first-seen revision while unchanged." }
            }
            if ($findingId -notin $priorOutstandingIds -and $priorLifecycleById.ContainsKey($findingId) -and [string]$priorLifecycleById[$findingId].status -eq 'resolved') {
                if ([string]$record.status -ne 'regressed' -or [string]$record.previousResolutionRevision -ne [string]$priorLifecycleById[$findingId].resolvedRevision -or [string]$record.firstSeenRevision -ne [string]$priorLifecycleById[$findingId].firstSeenRevision) { throw "Finding '$findingId' returned after resolution and must be marked regressed with its original first-seen and prior resolution revisions." }
            }
            elseif ($findingId -notin $priorOutstandingIds -and (-not $priorLifecycleById.ContainsKey($findingId) -or [string]$priorLifecycleById[$findingId].status -ne 'resolved') -and [string]$record.status -ne 'new') {
                throw "Finding '$findingId' has no prior active or resolved history and must be marked new."
            }
        }
        foreach ($findingId in $priorOutstandingIds | Where-Object { $_ -notin $currentOutstandingIds }) {
            $priorRecord = $priorLifecycleById[$findingId]
            if (-not $currentLifecycleById.ContainsKey($findingId) -or [string]$currentLifecycleById[$findingId].status -ne 'resolved' -or [string]$currentLifecycleById[$findingId].resolvedRevision -ne [string]$review.reviewedRevision -or [string]$currentLifecycleById[$findingId].firstSeenRevision -ne [string]$priorRecord.firstSeenRevision -or [string]$currentLifecycleById[$findingId].lastObservedRevision -ne [string]$priorRecord.lastObservedRevision) {
                throw "Previously outstanding finding '$findingId' must have a resolved lifecycle record at the current reviewed revision."
            }
        }
        foreach ($findingId in $currentLifecycleById.Keys | Where-Object { [string]$currentLifecycleById[$_].status -eq 'resolved' -and -not $priorLifecycleById.ContainsKey([string]$_) }) {
            throw "Resolved lifecycle '$findingId' has no prior finding history."
        }
        foreach ($findingId in $priorLifecycleById.Keys | Where-Object { [string]$priorLifecycleById[$_].status -eq 'resolved' -and $_ -notin $currentOutstandingIds }) {
            $priorRecord = $priorLifecycleById[$findingId]
            $currentRecord = if ($currentLifecycleById.ContainsKey([string]$findingId)) { $currentLifecycleById[[string]$findingId] } else { $null }
            if (-not $currentRecord -or [string]$currentRecord.status -ne 'resolved' -or [string]$currentRecord.firstSeenRevision -ne [string]$priorRecord.firstSeenRevision -or [string]$currentRecord.lastObservedRevision -ne [string]$priorRecord.lastObservedRevision -or [string]$currentRecord.resolvedRevision -ne [string]$priorRecord.resolvedRevision) { throw "Resolved finding history '$findingId' must be carried forward unchanged." }
        }
    }
    elseif (@($lifecycle | Where-Object { [string]$_.status -eq 'resolved' }).Count) {
        throw 'Resolved lifecycle records require a prior persisted review snapshot.'
    }
    elseif (@($lifecycle | Where-Object { [string]$_.status -ne 'new' }).Count) {
        throw 'The first persisted review must mark every active finding as new.'
    }
    return
}

if ($ArtifactName -eq 'review-verification.json') {
    if ($AgentId -ne 'review_verifier') { throw 'Only Review Verifier may publish review-verification.json.' }
    $verification = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-RequiredProperties -Document $verification -Names @('taskId','reviewedRevision','reviewArtifactSha256','verificationStatus','coverageVerification','findingVerifications','lifecycleVerifications','summary') -Label 'review-verification.json'
    if ([string]$verification.taskId -ne $TaskId) { throw "review-verification.json must identify task '$TaskId'." }
    $reviewPath = Join-Path $TaskRoot 'review-result.json'
    if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw 'review-verification.json requires review-result.json.' }
    $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $reviewSha256 = Get-EcosystemFileSha256 -Path $reviewPath
    if ([string]$verification.reviewArtifactSha256 -ne $reviewSha256 -or [string]$verification.reviewedRevision -ne [string]$review.reviewedRevision) {
        throw 'review-verification.json is stale for the current review artifact or reviewed revision.'
    }

    $coverageByDimension = @{}
    foreach ($entry in @($review.reviewCoverage)) { $coverageByDimension[[string]$entry.dimension] = $entry }
    $coverageVerification = @($verification.coverageVerification | Where-Object { $null -ne $_ })
    $verifiedDimensions = @($coverageVerification | ForEach-Object { [string]$_.dimension })
    if ($coverageVerification.Count -ne $reviewDimensions.Count -or @($verifiedDimensions | Select-Object -Unique).Count -ne $reviewDimensions.Count -or @($reviewDimensions | Where-Object { $_ -notin $verifiedDimensions }).Count) {
        throw 'coverageVerification must verify every reviewCoverage dimension exactly once.'
    }
    foreach ($entry in $coverageVerification) {
        Assert-RequiredProperties -Document $entry -Names @('dimension','claimedStatus','verdict','evidence','falsificationAttempts','notes') -Label "coverageVerification '$([string]$entry.dimension)'"
        $dimension = [string]$entry.dimension
        if (-not $coverageByDimension.ContainsKey($dimension) -or [string]$entry.claimedStatus -ne [string]$coverageByDimension[$dimension].status) { throw "coverageVerification '$dimension' does not match the Reviewer claim." }
        if ([string]$entry.verdict -notin @('confirmed','rejected') -or -not (Test-NonEmptyStringArray -Value $entry.evidence) -or -not (Test-NonEmptyStringArray -Value $entry.falsificationAttempts) -or [string]::IsNullOrWhiteSpace([string]$entry.notes)) { throw "coverageVerification '$dimension' lacks a supported verdict or independent evidence." }
    }

    $productIds = @($review.findings | ForEach-Object { [string]$_.id })
    $processIds = @($review.agentProcessFindings | ForEach-Object { [string]$_.id })
    $activeIds = @($productIds) + @($processIds)
    $findingVerifications = @($verification.findingVerifications | Where-Object { $null -ne $_ })
    $verifiedFindingIds = @($findingVerifications | ForEach-Object { [string]$_.findingId })
    if (@($verifiedFindingIds | Select-Object -Unique).Count -ne $verifiedFindingIds.Count -or $verifiedFindingIds.Count -ne $activeIds.Count -or @($activeIds | Where-Object { $_ -notin $verifiedFindingIds }).Count) {
        throw 'findingVerifications must verify every active finding exactly once and no others.'
    }
    foreach ($entry in $findingVerifications) {
        Assert-RequiredProperties -Document $entry -Names @('findingId','findingKind','verdict','evidence','falsificationAttempts','notes') -Label "findingVerification '$([string]$entry.findingId)'"
        $findingId = [string]$entry.findingId
        $expectedKind = if ($findingId -in $productIds) { 'product' } else { 'agent-process' }
        if ([string]$entry.findingKind -ne $expectedKind -or [string]$entry.verdict -notin @('confirmed','rejected','needs-human') -or -not (Test-NonEmptyStringArray -Value $entry.evidence) -or -not (Test-NonEmptyStringArray -Value $entry.falsificationAttempts) -or [string]::IsNullOrWhiteSpace([string]$entry.notes)) {
            throw "findingVerification '$findingId' has an invalid kind, verdict, or evidence."
        }
    }

    $lifecycle = @($review.findingLifecycle)
    $lifecycleById = @{}
    foreach ($entry in $lifecycle) { $lifecycleById[[string]$entry.findingId] = $entry }
    $lifecycleVerifications = @($verification.lifecycleVerifications | Where-Object { $null -ne $_ })
    $verifiedLifecycleIds = @($lifecycleVerifications | ForEach-Object { [string]$_.findingId })
    if (@($verifiedLifecycleIds | Select-Object -Unique).Count -ne $verifiedLifecycleIds.Count -or $verifiedLifecycleIds.Count -ne $lifecycle.Count -or @($lifecycleById.Keys | Where-Object { $_ -notin $verifiedLifecycleIds }).Count) {
        throw 'lifecycleVerifications must verify every lifecycle record exactly once and no others.'
    }
    foreach ($entry in $lifecycleVerifications) {
        Assert-RequiredProperties -Document $entry -Names @('findingId','claimedStatus','verdict','evidence','notes') -Label "lifecycleVerification '$([string]$entry.findingId)'"
        $findingId = [string]$entry.findingId
        if (-not $lifecycleById.ContainsKey($findingId) -or [string]$entry.claimedStatus -ne [string]$lifecycleById[$findingId].status -or [string]$entry.verdict -notin @('confirmed','rejected') -or -not (Test-NonEmptyStringArray -Value $entry.evidence) -or [string]::IsNullOrWhiteSpace([string]$entry.notes)) {
            throw "lifecycleVerification '$findingId' does not match the Reviewer lifecycle claim."
        }
    }
    $requiresReviewRework = @($coverageVerification | Where-Object { [string]$_.verdict -eq 'rejected' }).Count -gt 0 -or @($lifecycleVerifications | Where-Object { [string]$_.verdict -eq 'rejected' }).Count -gt 0
    $expectedStatus = if ($requiresReviewRework) { 'review-rework-required' } else { 'passed' }
    if ([string]$verification.verificationStatus -ne $expectedStatus) { throw "review-verification.json status must be '$expectedStatus' for its coverage and lifecycle verdicts." }
    return
}

if ($ArtifactName -notin @('implementation-result.json','developer-publication-evidence.json')) { return }
$artifact = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$artifact.taskId -ne $TaskId) { throw "$ArtifactName must identify task '$TaskId'." }
if ($AgentId -ne 'developer') { return }
if ($ArtifactName -eq 'developer-publication-evidence.json') { return }

$tests = @($artifact.tests)
foreach ($test in $tests) {
    $resultPairs = @(Get-CountPairs -Text ([string]$test.result))
    $evidencePairs = @(Get-CountPairs -Text ([string]$test.evidence))
    if ($resultPairs.Count -and $evidencePairs.Count) {
        $expectedPair = "$($resultPairs[0].Passed)/$($resultPairs[0].Total)"
        $conflicts = @($evidencePairs | Where-Object { "$($_.Passed)/$($_.Total)" -ne $expectedPair })
        if ($conflicts.Count) { throw "implementation-result.json contains contradictory result/evidence counts for '$([string]$test.command)'." }
    }
}

$evidencePath = Join-Path $TaskRoot 'developer-publication-evidence.json'
if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) { throw 'Developer outcome publication requires developer-publication-evidence.json.' }
$publication = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$publication.taskId -ne $TaskId) { throw 'developer-publication-evidence.json identifies a different task.' }

$artifactCommit = if ($artifact.PSObject.Properties['commit']) { [string]$artifact.commit } elseif ($artifact.PSObject.Properties['headCommit']) { [string]$artifact.headCommit } else { '' }
if (-not $artifactCommit -or $artifactCommit -ne [string]$publication.headCommit) { throw 'Implementation result head commit contradicts final publication evidence.' }
if ([string]$artifact.branch -ne [string]$publication.branch) { throw 'Implementation result branch contradicts final publication evidence.' }
if (-not [bool]$publication.worktreeClean) { throw 'Developer outcome publication requires final evidence from a clean worktree.' }

$workspace = [string]$publication.workspace
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { throw "Publication evidence workspace does not exist: $workspace" }
$liveBranch = (Invoke-GitReadOnly -Workspace $workspace -Arguments @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).Trim()
$liveHead = (Invoke-GitReadOnly -Workspace $workspace -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()
$liveUpstream = (Invoke-GitReadOnly -Workspace $workspace -Arguments @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}') | Select-Object -First 1).Trim()
$liveDivergence = (Invoke-GitReadOnly -Workspace $workspace -Arguments @('rev-list','--left-right','--count',"$liveUpstream...HEAD") | Select-Object -First 1).Trim()
$liveParts = @($liveDivergence -split '\s+' | Where-Object { $_ -ne '' })
$liveStatus = @(Invoke-GitReadOnly -Workspace $workspace -Arguments @('status','--porcelain'))
if ($liveBranch -ne [string]$publication.branch -or $liveHead -ne [string]$publication.headCommit -or $liveUpstream -ne [string]$publication.upstream) { throw 'Developer publication evidence is stale for the live branch, head, or upstream.' }
if ($liveParts.Count -ne 2 -or [int]$liveParts[0] -ne [int]$publication.branchDivergence.behindCount -or [int]$liveParts[1] -ne [int]$publication.branchDivergence.aheadCount) { throw 'Developer publication evidence is stale for live branch divergence.' }
if ($liveStatus.Count -ne 0) { throw 'Developer worktree changed after final publication evidence was generated.' }

$aheadCounts = [Collections.Generic.List[int]]::new()
if ($artifact.PSObject.Properties['commitState']) {
    foreach ($count in @(Get-AheadCounts -Text ([string]$artifact.commitState))) { $aheadCounts.Add([int]$count) }
}
foreach ($test in $tests) {
    foreach ($text in @([string]$test.result,[string]$test.evidence)) {
        foreach ($count in @(Get-AheadCounts -Text $text)) { $aheadCounts.Add([int]$count) }
    }
}
foreach ($count in $aheadCounts) {
    if ($count -ne [int]$publication.branchDivergence.aheadCount) { throw 'implementation-result.json contains contradictory branch-divergence evidence.' }
}

$gitTests = @($tests | Where-Object { [string]$_.command -match '(?i)\bgit\s+(?:status|rev-list)\b' })
foreach ($test in $gitTests) {
    if (-not $test.PSObject.Properties['publicationEvidenceId'] -or [string]$test.publicationEvidenceId -ne 'git-branch-divergence') {
        throw 'Git publication test evidence must reference git-branch-divergence.'
    }
}

foreach ($test in @($tests | Where-Object { [string]$_.command -match '(?i)\bInvoke-Pester\b' -and [string]$_.result -match '(?i)^passed\b' })) {
    if (-not $test.PSObject.Properties['publicationEvidenceId'] -or [string]::IsNullOrWhiteSpace([string]$test.publicationEvidenceId)) {
        throw "Passed Pester result '$([string]$test.command)' is missing publicationEvidenceId."
    }
    $record = @($publication.pester | Where-Object { [string]$_.evidenceId -eq [string]$test.publicationEvidenceId }) | Select-Object -First 1
    if (-not $record) { throw "Pester publication evidence '$([string]$test.publicationEvidenceId)' was not found." }
    if ([int]$record.failedCount -ne 0) { throw "Pester publication evidence '$([string]$record.evidenceId)' is not passing." }
    if ([string]$test.command -ne [string]$record.command) { throw "Pester command contradicts publication evidence '$([string]$record.evidenceId)'." }
    $expected = "$([int]$record.passedCount)/$([int]$record.totalCount)"
    $pairs = @(@(Get-CountPairs -Text ([string]$test.result)) + @(Get-CountPairs -Text ([string]$test.evidence)))
    if (-not $pairs.Count -or @($pairs | Where-Object { "$($_.Passed)/$($_.Total)" -ne $expected }).Count) {
        throw "Pester counts contradict final publication evidence '$([string]$record.evidenceId)'."
    }
}
