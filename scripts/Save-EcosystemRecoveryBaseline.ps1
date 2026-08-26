[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Workspace,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{16,128}$')][string] $FailureSignature,
    [Parameter(Mandatory)][string] $ArtifactPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$')][string] $RepairBranchPrefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedWorkspace = [IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath (Join-Path $resolvedWorkspace '.git'))) { throw 'The recovery workspace is not a Git repository.' }
$resolvedArtifactPath = [IO.Path]::GetFullPath($ArtifactPath)
$workspacePrefix = $resolvedWorkspace.TrimEnd('\') + '\'
if ($resolvedArtifactPath.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'The preservation artifact must be stored outside the ecosystem Git worktree.' }

$branch = ([string](& git -C $resolvedWorkspace branch --show-current)).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) { throw 'Ecosystem recovery cannot preserve changes from a detached HEAD.' }
if ($branch -in @('main','master')) {
    $signaturePrefix = $FailureSignature.Substring(0, [Math]::Min(12, $FailureSignature.Length))
    $branchBase = '{0}/{1}-{2}' -f $RepairBranchPrefix.TrimEnd('/'), $TaskId, $signaturePrefix
    $branch = $branchBase
    $suffix = 1
    while ($true) {
        & git -C $resolvedWorkspace show-ref --verify --quiet ('refs/heads/{0}' -f $branch)
        $showRefExitCode = [int]$LASTEXITCODE
        if ($showRefExitCode -eq 1) { break }
        if ($showRefExitCode -ne 0) { throw "Unable to inspect recovery branch '$branch'." }
        $suffix++
        $branch = '{0}-{1}' -f $branchBase, $suffix
    }
    & git -C $resolvedWorkspace switch -c $branch
    if ($LASTEXITCODE -ne 0) { throw "Unable to create recovery branch '$branch'." }
}
if ($branch -in @('main','master') -or $branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw 'Ecosystem recovery selected an unsafe branch.' }

$files = @(& git -C $resolvedWorkspace status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the ecosystem Git worktree.' }
if (-not $files.Count) {
    return [pscustomobject][ordered]@{ Status='clean'; Branch=$branch; Commit=$null; Files=@(); ArtifactPath=$null }
}

$parentCommit = ([string](& git -C $resolvedWorkspace rev-parse HEAD)).Trim()
if ($LASTEXITCODE -ne 0 -or $parentCommit -notmatch '^[a-f0-9]{40}$') { throw 'Unable to resolve the preservation parent commit.' }
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $gitAddOutput = @(& git -C $resolvedWorkspace add --all -- . 2>&1)
    $gitAddExitCode = [int]$LASTEXITCODE
}
finally { $ErrorActionPreference = $previousErrorActionPreference }
if ($gitAddExitCode -ne 0) { throw "Unable to stage pre-recovery ecosystem changes: $($gitAddOutput -join [Environment]::NewLine)" }

$commitMessage = "chore(ecosystem): preserve pre-recovery changes $($FailureSignature.Substring(0, 12))"
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $gitCommitOutput = @(& git -C $resolvedWorkspace commit -m $commitMessage 2>&1)
    $gitCommitExitCode = [int]$LASTEXITCODE
}
finally { $ErrorActionPreference = $previousErrorActionPreference }
if ($gitCommitExitCode -ne 0) { throw "Unable to commit pre-recovery ecosystem changes: $($gitCommitOutput -join [Environment]::NewLine)" }
$commit = ([string](& git -C $resolvedWorkspace rev-parse HEAD)).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Unable to verify the pre-recovery preservation commit.' }
$remaining = @(& git -C $resolvedWorkspace status --porcelain=v1)
if ($LASTEXITCODE -ne 0 -or $remaining.Count) { throw 'The preservation commit did not leave a clean ecosystem worktree.' }

$artifact = [ordered]@{
    taskId = $TaskId
    failureSignature = $FailureSignature
    branch = $branch
    parentCommit = $parentCommit
    preservationCommit = $commit
    files = @($files)
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
}
$artifactDirectory = Split-Path -Parent $resolvedArtifactPath
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
[IO.File]::WriteAllText($resolvedArtifactPath, (($artifact | ConvertTo-Json -Depth 8) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
[pscustomobject][ordered]@{ Status='preserved'; Branch=$branch; Commit=$commit; Files=@($files); ArtifactPath=$resolvedArtifactPath }
