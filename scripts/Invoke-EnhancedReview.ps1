[CmdletBinding()]
param(
    [ValidateSet('Poll','Daily','Manual')][string] $Mode = 'Manual',
    [string] $RepositoryId,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $VerifiedContextPath,
    [ValidateRange(0, [int]::MaxValue)][int] $PullRequestId = 0,
    [ValidateRange(0, 250)][int] $ManualMaxFilesPerReview = 0,
    [ValidateRange(0, 1000000)][int] $ManualMaxDiffCharacters = 0,
    [switch] $DryRun,
    [switch] $ForceReview,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (($ManualMaxFilesPerReview -gt 0 -or $ManualMaxDiffCharacters -gt 0) -and $Mode -ne 'Manual') { throw 'Manual review limit overrides are permitted only in Manual mode.' }
if ($PullRequestId -gt 0 -and $Mode -ne 'Manual') { throw 'PullRequestId selection is permitted only in Manual mode.' }
$sync = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$commentParameters = @{ ConfigPath=$ConfigPath }
if (-not [string]::IsNullOrWhiteSpace($RepositoryId)) { $commentParameters.RepositoryId = $RepositoryId }
if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $commentParameters.TaskId = $TaskId }
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $commentParameters.CodexHome = $CodexHome }
$comments = & (Join-Path $PSScriptRoot 'Get-ActivePullRequestComments.ps1') @commentParameters
$monitorRoot = Resolve-EcosystemPath -Value ([string]$config.review.monitorSkillRoot) -Config $config -CodexHome $CodexHome
$runner = Join-Path $monitorRoot 'scripts\run_pr_review_monitor.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Review monitor runner was not found: $runner" }
$forceKeys = if ([bool]$config.review.rerunWhenCommentsChange) { @($comments.ChangedPullRequestKeys) } else { @() }
$runnerParameters = @{ Mode=$Mode; DataRoot=$sync.DataRoot; DryRun=[bool]$DryRun; ForceReview=[bool]$ForceReview; ForceReviewKey=$forceKeys; PullRequestContextPath=[string]$comments.ContextPath; VerifiedContextPath=$VerifiedContextPath; PullRequestId=$PullRequestId; PendingChangesPath=[string]$comments.PendingPath; ManualMaxFilesPerReview=$ManualMaxFilesPerReview; ManualMaxDiffCharacters=$ManualMaxDiffCharacters }
if (-not [string]::IsNullOrWhiteSpace($RepositoryId)) { $runnerParameters.RepositoryId = $RepositoryId }
& $runner @runnerParameters
if ($LASTEXITCODE -ne 0) { throw "Review monitor exited with code $LASTEXITCODE." }
