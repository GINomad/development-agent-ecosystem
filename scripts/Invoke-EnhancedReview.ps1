[CmdletBinding()]
param(
    [ValidateSet('Poll','Daily','Manual')][string] $Mode = 'Manual',
    [string] $RepositoryId,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [switch] $DryRun,
    [switch] $ForceReview,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
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
$runnerParameters = @{ Mode=$Mode; DataRoot=$sync.DataRoot; DryRun=[bool]$DryRun; ForceReview=[bool]$ForceReview; ForceReviewKey=$forceKeys; PullRequestContextPath=[string]$comments.ContextPath; PendingChangesPath=[string]$comments.PendingPath }
if (-not [string]::IsNullOrWhiteSpace($RepositoryId)) { $runnerParameters.RepositoryId = $RepositoryId }
& $runner @runnerParameters
if ($LASTEXITCODE -ne 0) { throw "Review monitor exited with code $LASTEXITCODE." }
