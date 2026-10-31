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
    [switch] $ThrowOnFailure,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$statusPath = Join-Path $stateRoot ('health\scheduled-review-' + $Mode.ToLowerInvariant() + '.json')
$startedAtUtc = [DateTime]::UtcNow
$runId = [guid]::NewGuid().ToString('N')
function Get-BoundedReviewErrorSummary {
    param([Parameter(Mandatory)][string] $Message)
    $value = $Message -replace '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;\"]+', '$1[redacted]'
    $value = $value -replace '(?i)(token|password|secret|api[_-]?key)\s*[:=]\s*[\"'']?[^\s,;\"'']+', '$1=[redacted]'
    $value = $value -replace '[\r\n]+', ' '
    if ($value.Length -gt 480) { $value = $value.Substring(0,480) }
    return $value
}
function Write-ReviewScheduleStatus {
    param([Parameter(Mandatory)][string] $Status,[AllowNull()][string] $Summary)
    $payload = [ordered]@{ schemaVersion='1.0.0'; kind='scheduled-review'; mode=$Mode.ToLowerInvariant(); runId=$runId; status=$Status; checkedAtUtc=[DateTime]::UtcNow.ToString('o'); startedAtUtc=$startedAtUtc.ToString('o'); completedAtUtc=[DateTime]::UtcNow.ToString('o'); durationMs=[int]([DateTime]::UtcNow-$startedAtUtc).TotalMilliseconds }
    $previous=$null; if(Test-Path -LiteralPath $statusPath -PathType Leaf){try{$previous=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
    if($Status -eq 'succeeded'){$payload.lastSucceededAtUtc=$payload.completedAtUtc;$payload.lastSuccessfulRunId=$runId}
    elseif($previous -and $previous.PSObject.Properties['lastSucceededAtUtc']){$payload.lastSucceededAtUtc=[string]$previous.lastSucceededAtUtc;if($previous.PSObject.Properties['lastSuccessfulRunId']){$payload.lastSuccessfulRunId=[string]$previous.lastSuccessfulRunId}}
    if ($Status -eq 'failed') { $payload.error=[ordered]@{ classification='runner'; summary=(Get-BoundedReviewErrorSummary -Message $Summary) } }
    Write-Utf8NoBomAtomic -Path $statusPath -Content (($payload | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    return [pscustomobject]$payload
}
try {
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
$global:LASTEXITCODE = 0
& $runner @runnerParameters
$runnerExitCode = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $runnerExitCode -and $runnerExitCode -ne 0) { throw "Review monitor exited with code $runnerExitCode." }
Write-ReviewScheduleStatus -Status 'succeeded' -Summary $null | Out-Null
}
catch {
    $summary = $_.Exception.Message
    try { Write-ReviewScheduleStatus -Status 'failed' -Summary $summary | Out-Null } catch { }
    throw
}
