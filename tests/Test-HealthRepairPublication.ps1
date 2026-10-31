[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Publish-VerifiedHealthRepair.ps1')
$fixture = Join-Path $OutputRoot ('health-publication-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null

function Invoke-Git([string] $Path, [string[]] $Arguments) {
    $output = @(& git -C $Path @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' '): $($output -join [Environment]::NewLine)" }
    return $output
}
function New-Commit([string] $Path, [string] $Name, [string] $Content) {
    Set-Content -LiteralPath (Join-Path $Path $Name) -Value $Content -NoNewline
    Invoke-Git $Path @('add', '--', $Name) | Out-Null
    Invoke-Git $Path @('-c', 'user.name=Health Test', '-c', 'user.email=health@example.test', 'commit', '-m', $Name) | Out-Null
    return ([string](Invoke-Git $Path @('rev-parse', 'HEAD'))).Trim()
}
function Assert-Throws([scriptblock] $Action, [string] $Expected) {
    try { & $Action } catch { if ($_.Exception.Message -match $Expected) { return }; throw }
    throw "Expected failure matching '$Expected'."
}
function New-Proof([string] $Path, [string] $Commit) {
    $fingerprint = & (Join-Path $root 'scripts\Get-EcosystemSourceFingerprint.ps1') -Root $Path
    return [pscustomobject]@{ Passed=$true; Commit=$Commit; Fingerprint=[string]$fingerprint.Fingerprint }
}
try {
    $remote = Join-Path $fixture 'origin.git'; $work = Join-Path $fixture 'work'; $racer = Join-Path $fixture 'racer'
    & git init --bare --initial-branch=main $remote | Out-Null
    & git clone $remote $work | Out-Null
    Invoke-Git $work @('config', 'user.name', 'Health Test') | Out-Null; Invoke-Git $work @('config', 'user.email', 'health@example.test') | Out-Null
    $initial = New-Commit $work 'initial.txt' 'initial'; Invoke-Git $work @('push', 'origin', 'main') | Out-Null
    $policy = [pscustomobject]@{ pushVerifiedRepairs=$true; mergeVerifiedRepairsToMain=$true; pushRemote='origin'; pushRemoteUrl=$remote; targetBranch='main' }
    $repair = New-Commit $work 'repair.txt' 'repair'
    Invoke-Git $work @('-c', 'user.name=Health Test', '-c', 'user.email=health@example.test', 'tag', '-a', 'must-not-publish', '-m', 'must-not-publish', $repair) | Out-Null
    Invoke-Git $work @('config', 'push.followTags', 'true') | Out-Null
    $receipt = Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $repair -ValidationProof (New-Proof $work $repair) -Policy $policy
    if ($receipt.deliveryState -ne 'delivered' -or $receipt.repairCommit -ne $repair -or $receipt.deliveredMainCommit -ne $repair) { throw 'Normal fast-forward main publication receipt is invalid.' }
    if (@(Invoke-Git $work @('ls-remote', '--tags', 'origin', 'refs/tags/must-not-publish')).Count -ne 0) { throw 'Health publication followed an annotated tag despite the no-tags policy.' }
    $idempotent = Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $repair -ValidationProof (New-Proof $work $repair) -Policy $policy
    if ($idempotent.deliveryState -ne 'already-delivered') { throw 'Already-delivered publication is not idempotent.' }
    $migrationRepair = New-Commit $work 'migration.txt' 'migration'
    $legacySnapshotPolicy = [pscustomobject]@{ pushVerifiedRepairs=$true; pushRemote='origin'; pushRemoteUrl=$remote }
    $migrationReceipt = Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $migrationRepair -ValidationProof (New-Proof $work $migrationRepair) -Policy $legacySnapshotPolicy
    if ($migrationReceipt.targetBranch -ne 'main' -or $migrationReceipt.deliveredMainCommit -ne $migrationRepair) { throw 'An older configuration snapshot did not safely default to main publication.' }
    $staleFingerprint = (New-Proof $work $migrationRepair).Fingerprint
    $staleContentCommit = New-Commit $work 'stale-content.txt' 'stale-content'
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $staleContentCommit -ValidationProof ([pscustomobject]@{ Passed=$true; Commit=$staleContentCommit; Fingerprint=$staleFingerprint }) -Policy $policy } 'source fingerprint'
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $staleContentCommit -ValidationProof (New-Proof $work $migrationRepair) -Policy $policy } 'validation proof'
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $staleContentCommit -ValidationProof ([pscustomobject]@{}) -Policy $policy } 'validation proof'
    Set-Content -LiteralPath (Join-Path $work 'dirty.txt') -Value 'dirty'
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $repair -ValidationProof (New-Proof $work $repair) -Policy $policy } 'clean worktree'
    Remove-Item -LiteralPath (Join-Path $work 'dirty.txt') -Force
    $wrongOrigin = [pscustomobject]@{ pushVerifiedRepairs=$true; mergeVerifiedRepairsToMain=$true; pushRemote='origin'; pushRemoteUrl=($remote + '-wrong'); targetBranch='main' }
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $repair -ValidationProof (New-Proof $work $repair) -Policy $wrongOrigin } 'exact configured ecosystem remote URL'
    $historyWork = Join-Path $fixture 'history-work'; & git clone $remote $historyWork | Out-Null
    Invoke-Git $historyWork @('config', 'user.name', 'History'); Invoke-Git $historyWork @('config', 'user.email', 'history@example.test') | Out-Null
    $privateHistoryCommit = New-Commit $historyWork 'private-history.txt' 'private-history'
    $privateBlob = ([string](Invoke-Git $historyWork @('rev-parse', "$privateHistoryCommit`:private-history.txt"))).Trim()
    $privateFingerprintPath = Join-Path $historyWork 'knowledge\local\private-history-fingerprints.local.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $privateFingerprintPath) -Force | Out-Null
    Set-Content -LiteralPath $privateFingerprintPath -Value ((@([ordered]@{ sha=$privateBlob }) | ConvertTo-Json -Compress)) -NoNewline
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $historyWork -Commit $privateHistoryCommit -ValidationProof (New-Proof $historyWork $privateHistoryCommit) -Policy $policy } 'Publication history contains a known private blob'
    & git clone $remote $racer | Out-Null
    Invoke-Git $racer @('config', 'user.name', 'Racer'); Invoke-Git $racer @('config', 'user.email', 'racer@example.test') | Out-Null
    $remoteAdvance = New-Commit $racer 'advance.txt' 'advance'; Invoke-Git $racer @('push', 'origin', 'main') | Out-Null
    $unreviewed = New-Commit $work 'unreviewed.txt' 'unreviewed'
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $work -Commit $unreviewed -ValidationProof (New-Proof $work $unreviewed) -Policy $policy } 'does not fast-forward'
    if (([string](Invoke-Git $work @('rev-parse', 'refs/remotes/origin/main'))).Trim() -eq $unreviewed) { throw 'Divergent main refusal unexpectedly published the repair.' }
    $raceCommit = New-Commit $racer 'race.txt' 'race'
    $raceReceipt = Invoke-VerifiedHealthRepairPublication -Workspace $racer -Commit $raceCommit -ValidationProof (New-Proof $racer $raceCommit) -Policy $policy
    if ($raceReceipt.deliveredMainCommit -ne $raceCommit) { throw 'Remote advance publication did not verify the delivered main commit.' }
    $raceWork = Join-Path $fixture 'push-race-work'; $raceRacer = Join-Path $fixture 'push-race-racer'
    & git clone $remote $raceWork | Out-Null; & git clone $remote $raceRacer | Out-Null
    foreach ($clone in @($raceWork, $raceRacer)) { Invoke-Git $clone @('config', 'user.name', 'Push Race'); Invoke-Git $clone @('config', 'user.email', 'push-race@example.test') | Out-Null }
    $prePushRepair = New-Commit $raceWork 'pre-push-repair.txt' 'pre-push-repair'
    $prePushSibling = New-Commit $raceRacer 'pre-push-sibling.txt' 'pre-push-sibling'
    $hookPath = Join-Path $raceWork '.git\hooks\pre-push'
    $raceRacerForHook = $raceRacer.Replace('\', '/')
    Set-Content -LiteralPath $hookPath -Value ("#!/bin/sh`nunset GIT_DIR`nunset GIT_WORK_TREE`ngit -C '$raceRacerForHook' push origin main`n") -NoNewline
    Assert-Throws { Invoke-VerifiedHealthRepairPublication -Workspace $raceWork -Commit $prePushRepair -ValidationProof (New-Proof $raceWork $prePushRepair) -Policy $policy } 'Unable to fast-forward'
    $remoteAfterRace = ([string](Invoke-Git $raceWork @('ls-remote', '--heads', 'origin', 'refs/heads/main'))).Split("`t")[0]
    if ($remoteAfterRace -ne $prePushSibling) { throw 'The deterministic pre-push race did not preserve the concurrent sibling main advance.' }
    [pscustomobject]@{ Passed=$true; Checks=@('normal-fast-forward-main','older-snapshot-main-default','stale-content-proof-refusal','wrong-commit-proof-refusal','private-history-refusal','divergent-main-refusal','origin-mismatch','dirty-worktree','missing-validation-proof','remote-advance','real-pre-push-race-refusal','already-delivered-idempotence') }
}
finally {
    $resolvedOutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\','/')
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $requiredPrefix = $resolvedOutputRoot + [IO.Path]::DirectorySeparatorChar + 'health-publication-'
    if (-not $resolvedFixture.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a publication fixture outside the generated output-root prefix.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
