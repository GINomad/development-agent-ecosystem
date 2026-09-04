[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\review-verification')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\AgentEcosystem.psm1') -Force

$root = Get-EcosystemRoot
$taskId = 'rv-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$runRoot = Join-Path $OutputRoot $taskId
$stateRoot = Join-Path $runRoot 'state'
$testConfigPath = Join-Path $runRoot 'agents.json'
$taskRoot = Join-Path $stateRoot "tasks\$taskId"
$reviewPath = Join-Path $taskRoot 'review-result.json'
$verificationPath = Join-Path $taskRoot 'review-verification.json'
$dimensions = @('requirements','correctness','security','regression','testing','maintainability','performance','concurrency','configuration-deployment','documentation')

function Write-JsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Utf8NoBom -Path $Path -Content (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock] $Action, [Parameter(Mandatory)][string] $Pattern)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern', received: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected action to fail with '$Pattern'."
}

function New-CoverageMatrix {
    @($dimensions | ForEach-Object {
        [ordered]@{
            dimension = $_
            status = 'covered'
            evidence = @("direct evidence for $_")
            notes = "Reviewed $_ against the current revision."
        }
    })
}

function New-Finding {
    [ordered]@{
        id = 'REV-101'
        severity = 'high'
        category = 'correctness'
        location = 'src/example.ps1:17'
        evidence = 'The current branch reproduces the incorrect transition.'
        impact = 'A valid task can skip its required gate.'
        correctionDirection = 'Preserve the gate until independent verification succeeds.'
        decisionStatus = 'proposed'
    }
}

function New-Review {
    param(
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][ValidateSet('new','unchanged','resolved','regressed')][string] $LifecycleStatus
    )
    $active = $LifecycleStatus -ne 'resolved'
    [object[]] $currentFindings = @()
    if ($active) { $currentFindings = @((New-Finding)) }
    $lifecycle = [ordered]@{
        findingId = 'REV-101'
        status = $LifecycleStatus
        firstSeenRevision = 'rev-1'
        lastObservedRevision = if ($active) { $Revision } else { 'rev-2' }
        evidence = "Lifecycle $LifecycleStatus was checked at $Revision."
    }
    if ($LifecycleStatus -eq 'resolved') { $lifecycle.resolvedRevision = $Revision }
    if ($LifecycleStatus -eq 'regressed') { $lifecycle.previousResolutionRevision = 'rev-3' }
    [ordered]@{
        taskId = $taskId
        reviewedRevision = $Revision
        requirementsRevision = 'requirements-v1'
        requirementTraceability = @([ordered]@{
            requirementId = 'REQ-1'
            requirementText = 'Review must use an independent verifier.'
            implementationStatus = 'verified'
            codeReferences = @([ordered]@{
                repositoryId = 'synthetic'
                filePath = 'src/example.ps1'
                startLine = 17
                evidence = 'The gate is represented at this line.'
            })
            testEvidence = @('Targeted review verification test')
            notes = 'Synthetic contract fixture.'
        })
        reviewCoverage = @(New-CoverageMatrix)
        findings = $currentFindings
        heldScopeViolations = @()
        agentProcessFindings = @()
        findingLifecycle = @($lifecycle)
        summary = "Review at $Revision with lifecycle $LifecycleStatus."
    }
}

function New-Verification {
    param(
        [Parameter(Mandatory)] $Review,
        [ValidateSet('confirmed','rejected')][string] $FindingVerdict = 'confirmed',
        [ValidateSet('confirmed','rejected')][string] $LifecycleVerdict = 'confirmed',
        [ValidateSet('passed','review-rework-required')][string] $Status = 'passed'
    )
    $reviewSha256 = (Get-FileHash -LiteralPath $reviewPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [object[]] $findingVerifications = @()
    if (@($Review.findings).Count) {
        $findingVerifications = @([ordered]@{
            findingId = 'REV-101'
            findingKind = 'product'
            verdict = $FindingVerdict
            evidence = @('Independent reproduction evidence.')
            falsificationAttempts = @('Tested the inverse transition and nearby boundary.')
            notes = 'Independent finding verdict.'
        })
    }
    [ordered]@{
        taskId = $taskId
        reviewedRevision = [string]$Review.reviewedRevision
        reviewArtifactSha256 = $reviewSha256
        verificationStatus = $Status
        coverageVerification = @($Review.reviewCoverage | ForEach-Object {
            [ordered]@{
                dimension = [string]$_.dimension
                claimedStatus = [string]$_.status
                verdict = 'confirmed'
                evidence = @("independent evidence for $([string]$_.dimension)")
                falsificationAttempts = @("attempted to disprove $([string]$_.dimension) coverage")
                notes = 'The claim survived the independent check.'
            }
        })
        findingVerifications = [object[]]@($findingVerifications)
        lifecycleVerifications = @($Review.findingLifecycle | ForEach-Object {
            [ordered]@{
                findingId = [string]$_.findingId
                claimedStatus = [string]$_.status
                verdict = $LifecycleVerdict
                evidence = @('Compared current evidence with immutable prior snapshots.')
                notes = 'Independent lifecycle verdict.'
            }
        })
        summary = 'Independent verification completed.'
    }
}

New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$testConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$testConfig.runtime.stateRoot = $stateRoot
Write-JsonFile -Path $testConfigPath -Value $testConfig
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskId -TaskSelector 'synthetic-review-verification' -Mode manual -ConfigPath $testConfigPath | Out-Null

$reviewOne = New-Review -Revision 'rev-1' -LifecycleStatus new
Write-JsonFile -Path $reviewPath -Value $reviewOne
& (Join-Path $root 'scripts\Publish-AgentOutcome.ps1') -TaskId $taskId -AgentId reviewer -Summary 'Synthetic first review published.' -ArtifactNames 'review-result.json' -ConfigPath $testConfigPath | Out-Null
$snapshotOne = & (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath
$snapshotOneRepeat = & (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath
$historyOne = Get-Content -LiteralPath $snapshotOne.IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($historyOne.snapshots).Count -ne 1 -or [string]$snapshotOne.ReviewSha256 -ne [string]$snapshotOneRepeat.ReviewSha256) {
    throw 'Review snapshots must be immutable and idempotent for the same artifact hash.'
}

$reviewTwo = New-Review -Revision 'rev-2' -LifecycleStatus unchanged
Write-JsonFile -Path $reviewPath -Value $reviewTwo
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
& (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath | Out-Null

$reviewThree = New-Review -Revision 'rev-3' -LifecycleStatus resolved
Write-JsonFile -Path $reviewPath -Value $reviewThree
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
& (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath | Out-Null

$reviewFour = New-Review -Revision 'rev-4' -LifecycleStatus regressed
Write-JsonFile -Path $reviewPath -Value $reviewFour
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot

$invalidLifecycle = $reviewFour | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$invalidLifecycle.findingLifecycle[0].firstSeenRevision = 'rev-4'
Write-JsonFile -Path $reviewPath -Value $invalidLifecycle
Assert-Throws -Pattern 'original first-seen' -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
}
Write-JsonFile -Path $reviewPath -Value $reviewFour
& (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath | Out-Null

& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -Status review_pending -AgentId reviewer -AgentStatus completed -Stage review_completed -Message 'Synthetic Reviewer outcome is ready for independent verification.' -ConfigPath $testConfigPath | Out-Null
$reviewContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $taskId -CompletedAgentId reviewer -PrepareOnly -ConfigPath $testConfigPath
if ([string]$reviewContinuation.Status -ne 'prepared' -or [string]$reviewContinuation.NextAgentId -ne 'review_verifier') {
    throw 'Reviewer completion must route to the independent Review Verifier.'
}

$verification = New-Verification -Review $reviewFour
Write-JsonFile -Path $verificationPath -Value $verification
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot

$emptyFalsificationVerification = $verification | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$emptyFalsificationVerification.coverageVerification[0].falsificationAttempts = @()
Write-JsonFile -Path $verificationPath -Value $emptyFalsificationVerification
Assert-Throws -Pattern 'lacks a supported verdict or independent evidence' -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
}

$staleVerification = $verification | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$staleVerification.reviewArtifactSha256 = ('0' * 64)
Write-JsonFile -Path $verificationPath -Value $staleVerification
Assert-Throws -Pattern 'stale' -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
}

$invalidReview = $reviewFour | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$invalidReview.reviewCoverage = @($invalidReview.reviewCoverage | Select-Object -First 9)
Write-JsonFile -Path $reviewPath -Value $invalidReview
Assert-Throws -Pattern 'every configured review dimension exactly once' -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
}

Write-JsonFile -Path $reviewPath -Value $reviewFour
$rejectedFindingVerification = New-Verification -Review $reviewFour -FindingVerdict rejected
Write-JsonFile -Path $verificationPath -Value $rejectedFindingVerification
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
Assert-Throws -Pattern 'rejected by Review Verifier' -Action {
    & (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $taskId -FindingId 'REV-101' -Decision approved -DecidedBy 'test-user' -ConfigPath $testConfigPath
}

$rejectedLifecycleVerification = New-Verification -Review $reviewFour -LifecycleVerdict rejected -Status review-rework-required
Write-JsonFile -Path $verificationPath -Value $rejectedLifecycleVerification
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
$rejectedLifecycleVerification.verificationStatus = 'passed'
Write-JsonFile -Path $verificationPath -Value $rejectedLifecycleVerification
Assert-Throws -Pattern "status must be 'review-rework-required'" -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
}

$rejectedLifecycleVerification.verificationStatus = 'review-rework-required'
Write-JsonFile -Path $verificationPath -Value $rejectedLifecycleVerification
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -Status review_pending -AgentId review_verifier -AgentStatus completed -Stage verification_completed -Message 'Synthetic verification requires Reviewer rework.' -ConfigPath $testConfigPath | Out-Null
$reworkContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $taskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $testConfigPath
if ([string]$reworkContinuation.Status -ne 'prepared' -or [string]$reworkContinuation.NextAgentId -ne 'reviewer') {
    throw 'Rejected coverage or lifecycle verification must route back to Reviewer.'
}
$reworkTask = Get-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$reworkTask.agentStatuses.reviewer.status -ne 'pending' -or [string]$reworkTask.agentStatuses.review_verifier.status -ne 'pending') {
    throw 'Reviewer and Review Verifier must both be reset before rework verification.'
}

Write-JsonFile -Path $verificationPath -Value $rejectedFindingVerification
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -Status review_pending -AgentId reviewer -AgentStatus completed -Stage review_completed -Message 'Synthetic corrected review completed.' -ConfigPath $testConfigPath | Out-Null
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -AgentId review_verifier -AgentStatus completed -Stage verification_completed -Message 'Synthetic finding was rejected by the independent verifier.' -ConfigPath $testConfigPath | Out-Null
$rejectedFindingContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $taskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $testConfigPath
if ([string]$rejectedFindingContinuation.Status -ne 'prepared' -or [string]$rejectedFindingContinuation.NextAgentId -ne 'pipeline_monitor') {
    throw 'A verifier-rejected finding must remain auditable without blocking pipeline continuation.'
}

Write-JsonFile -Path $verificationPath -Value $verification
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -Status review_pending -AgentId review_verifier -AgentStatus completed -Stage verification_completed -Message 'Synthetic finding was confirmed by the independent verifier.' -ConfigPath $testConfigPath | Out-Null
$confirmedFindingContinuation = & (Join-Path $root 'scripts\Continue-AgentChain.ps1') -TaskId $taskId -CompletedAgentId review_verifier -PrepareOnly -ConfigPath $testConfigPath
if ([string]$confirmedFindingContinuation.Status -ne 'review-pending' -or [string]$confirmedFindingContinuation.Reason -notmatch 'undecided') {
    throw 'A verifier-confirmed finding without a human decision must stop at the review decision gate.'
}

$decision = & (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $taskId -FindingId 'REV-101' -Decision approved -DecidedBy 'test-user' -ConfigPath $testConfigPath
if ([string]$decision.reviewedRevision -ne 'rev-4' -or [string]$decision.reviewArtifactSha256 -ne [string]$verification.reviewArtifactSha256 -or [string]$decision.verificationVerdict -ne 'confirmed') {
    throw 'A human decision must be bound to the exact independently verified review artifact.'
}

$bypassDecision = & (Join-Path $root 'scripts\Set-ReviewDecision.ps1') -TaskId $taskId -FindingId 'REV-101' -Decision bypassed -DecidedBy 'test-user' -Note 'Accepted temporarily and tracked as explicit review debt.' -ConfigPath $testConfigPath
if ([string]$bypassDecision.techDebtItemId -ne 'TD-REV-101') { throw 'A bypass decision must create exact-review-bound technical debt.' }
$debtPath = Join-Path $taskRoot 'tech-debt-items.json'
$legacyDebt = Get-Content -LiteralPath $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($propertyName in @('reviewVerificationArtifact','reviewedRevision','reviewArtifactSha256')) { $legacyDebt.items[0].PSObject.Properties.Remove($propertyName) }
Write-JsonFile -Path $debtPath -Value $legacyDebt
$migratedDebt = & (Join-Path $root 'scripts\New-ReviewTechDebtItem.ps1') -TaskId $taskId -FindingId 'REV-101' -Reason 'Accepted temporarily and migrated to exact review binding.' -CreatedBy 'test-user' -ConfigPath $testConfigPath
if ([string]$migratedDebt.reviewArtifactSha256 -ne [string]$verification.reviewArtifactSha256 -or [string]$migratedDebt.reviewedRevision -ne 'rev-4' -or @($migratedDebt.previousReviewBindings).Count -ne 1) {
    throw 'Legacy bypass debt must migrate fail-closed to the current independently verified review binding.'
}
$resolvedDebt = Get-Content -LiteralPath $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json
$resolvedDebt.items[0].status = 'resolved'
Write-JsonFile -Path $debtPath -Value $resolvedDebt
$reopenedDebt = & (Join-Path $root 'scripts\New-ReviewTechDebtItem.ps1') -TaskId $taskId -FindingId 'REV-101' -Reason 'Explicitly bypassed again after debt resolution.' -CreatedBy 'test-user' -ConfigPath $testConfigPath
if ([string]$reopenedDebt.status -ne 'open' -or [string]$reopenedDebt.reviewArtifactSha256 -ne [string]$verification.reviewArtifactSha256) {
    throw 'A repeated explicit bypass must reopen the exact-review-bound technical-debt item.'
}
$invalidDebtReview = New-Review -Revision 'rev-5' -LifecycleStatus unchanged
Write-JsonFile -Path $reviewPath -Value $invalidDebtReview
Assert-Throws -Pattern 'must be omitted from active findings' -Action {
    & (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
}
$reviewFive = New-Review -Revision 'rev-5' -LifecycleStatus unchanged
$reviewFive.findings = @()
$reviewFive.summary = 'The finding remains observable but is represented by open bypass debt instead of the active decision gate.'
$reviewFive.findingLifecycle[0].evidence = 'REV-101 remains observable at rev-5 and is tracked by open TD-REV-101.'
Write-JsonFile -Path $reviewPath -Value $reviewFive
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId reviewer -ArtifactName 'review-result.json' -Path $reviewPath -TaskRoot $taskRoot
& (Join-Path $root 'scripts\Save-ReviewArtifactSnapshot.ps1') -TaskId $taskId -ConfigPath $testConfigPath | Out-Null
$verificationFive = New-Verification -Review $reviewFive
Write-JsonFile -Path $verificationPath -Value $verificationFive
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId $taskId -AgentId review_verifier -ArtifactName 'review-verification.json' -Path $verificationPath -TaskRoot $taskRoot
if (@($verificationFive.findingVerifications).Count -ne 0 -or [string]$verificationFive.lifecycleVerifications[0].claimedStatus -ne 'unchanged') {
    throw 'Open bypass debt must remain lifecycle-auditable without re-entering active finding verification.'
}

[pscustomobject][ordered]@{
    Status = 'passed'
    TaskId = $taskId
    OutputRoot = $runRoot
    Snapshots = @((Get-Content -LiteralPath $snapshotOne.IndexPath -Raw -Encoding UTF8 | ConvertFrom-Json).snapshots).Count
    Checks = @(
        'review coverage completeness',
        'new/unchanged/resolved/regressed lifecycle',
        'immutable review snapshots',
        'exact review hash binding',
        'independent finding gate',
        'verification rework status',
        'reviewer/verifier/pipeline control-plane routing',
        'open bypass debt remains unchanged, not falsely resolved',
        'legacy bypass debt exact-SHA migration and explicit reopen'
    )
}
