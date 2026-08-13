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
