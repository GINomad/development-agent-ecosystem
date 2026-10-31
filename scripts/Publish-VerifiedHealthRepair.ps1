Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-VerifiedHealthRepairPublication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Workspace,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $Commit,
        [Parameter(Mandatory)][psobject] $ValidationProof,
        [Parameter(Mandatory)][psobject] $Policy
    )

    # Preserve any preconfigured noninteractive credential helper (including
    # `gh auth git-credential`), but prohibit terminal/UI credential prompts.
    # This helper never reads or materializes credentials.
    $previousTerminalPrompt = [Environment]::GetEnvironmentVariable('GIT_TERMINAL_PROMPT', 'Process')
    [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', '0', 'Process')
    try {
    $mergeVerifiedRepairsToMain = -not $Policy.PSObject.Properties['mergeVerifiedRepairsToMain'] -or [bool]$Policy.mergeVerifiedRepairsToMain
    if (-not [bool]$Policy.pushVerifiedRepairs -or -not $mergeVerifiedRepairsToMain) { throw 'Verified Health repair publication is not enabled by policy.' }
    $remote = [string]$Policy.pushRemote
    $targetBranch = if ($Policy.PSObject.Properties['targetBranch']) { [string]$Policy.targetBranch } else { 'main' }
    if ($remote -ne 'origin' -or $targetBranch -notin @('main', 'master')) { throw 'Health recovery may publish only to the configured origin base branch.' }
    if ($targetBranch -ne 'main') { throw 'Health recovery may publish only to origin/main.' }
    $configuredRemoteUrl = [string]$Policy.pushRemoteUrl
    $actualRemoteUrl = ([string](& git -C $Workspace -c credential.interactive=false remote get-url $remote)).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualRemoteUrl -ne $configuredRemoteUrl) { throw 'Health recovery origin does not match the exact configured ecosystem remote URL.' }
    & (Join-Path $PSScriptRoot 'Test-PublicationBoundary.ps1') -Root $Workspace -Revision $Commit -History | Out-Null
    $gitCredentialOptions = @('-c', 'credential.interactive=false')
    if ($actualRemoteUrl -eq 'https://github.com/GINomad/development-agent-ecosystem.git' -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        # Scope the existing GitHub CLI credential helper to this command only;
        # it supplies credentials directly to Git without exposing them here.
        $gitCredentialOptions = @('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential') + $gitCredentialOptions
    }
    if ((@(& git -C $Workspace status --porcelain)).Count -ne 0) { throw 'Validated ecosystem repair publication requires a clean worktree.' }
    $validatedCommit = ([string](& git -C $Workspace rev-parse ("{0}^{{commit}}" -f $Commit))).Trim()
    if ($LASTEXITCODE -ne 0 -or $validatedCommit -ne $Commit) { throw 'The validated ecosystem repair commit cannot be resolved locally.' }
    $headCommit = ([string](& git -C $Workspace rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $headCommit -ne $Commit) { throw 'Verified Health repair publication requires the validated repair to be the current HEAD.' }
    $currentSource = & (Join-Path $PSScriptRoot 'Get-EcosystemSourceFingerprint.ps1') -Root $Workspace
    if (-not $ValidationProof.PSObject.Properties['Passed'] -or -not [bool]$ValidationProof.Passed -or -not $ValidationProof.PSObject.Properties['Commit'] -or [string]$ValidationProof.Commit -ne $Commit -or -not $ValidationProof.PSObject.Properties['Fingerprint'] -or [string]::IsNullOrWhiteSpace([string]$ValidationProof.Fingerprint) -or [string]$ValidationProof.Fingerprint -ne [string]$currentSource.Fingerprint) { throw 'Verified Health repair publication requires a successful validation proof bound to the exact repair commit and source fingerprint.' }

    function Get-RemoteMainCommit {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& git -C $Workspace @gitCredentialOptions ls-remote --heads $remote ("refs/heads/{0}" -f $targetBranch) 2>&1)
            $exitCode = [int]$LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        $line = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[a-f0-9]{40}\s+refs/heads/' } | Select-Object -First 1)
        if ($exitCode -ne 0 -or $line.Count -ne 1) { throw 'Unable to resolve the configured remote publication branch.' }
        return (($line[0] -split '\s+')[0])
    }
    function Test-RemoteContainsCommit([string] $RemoteCommit, [string] $CandidateCommit) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            @(& git -C $Workspace @gitCredentialOptions fetch --no-tags $remote ("refs/heads/{0}" -f $targetBranch) 2>&1) | Out-Null
            $fetchExitCode = [int]$LASTEXITCODE
            if ($fetchExitCode -ne 0) { return $false }
            & git -C $Workspace merge-base --is-ancestor $CandidateCommit $RemoteCommit 2>$null
            return [int]$LASTEXITCODE -eq 0
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
    }

    $beforeCommit = Get-RemoteMainCommit
    if (Test-RemoteContainsCommit -RemoteCommit $beforeCommit -CandidateCommit $Commit) {
        return [pscustomobject][ordered]@{ remote=$remote; remoteUrl=$actualRemoteUrl; targetBranch=$targetBranch; repairCommit=$Commit; deliveredMainCommit=$beforeCommit; deliveryState='already-delivered'; branch=$targetBranch; commit=$Commit; deliveredCommit=$beforeCommit; pushRef=$null; verifiedAtUtc=[DateTime]::UtcNow.ToString('o') }
    }
    if (-not (Test-RemoteContainsCommit -RemoteCommit $Commit -CandidateCommit $beforeCommit)) { throw 'The validated repair does not fast-forward the current remote base branch.' }
    $pushRef = '{0}:refs/heads/{1}' -f $Commit, $targetBranch
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pushOutput = @(& git -C $Workspace @gitCredentialOptions push --no-follow-tags $remote $pushRef 2>&1)
        $pushExitCode = [int]$LASTEXITCODE
    } finally { $ErrorActionPreference = $previousErrorActionPreference }
    $afterCommit = Get-RemoteMainCommit
    if (-not (Test-RemoteContainsCommit -RemoteCommit $afterCommit -CandidateCommit $Commit)) {
        if ($pushExitCode -ne 0) { throw ('Unable to fast-forward the configured remote base branch: {0}' -f ($pushOutput -join [Environment]::NewLine)) }
        throw 'Remote base branch changed without retaining the validated repair commit.'
    }
    [pscustomobject][ordered]@{ remote=$remote; remoteUrl=$actualRemoteUrl; targetBranch=$targetBranch; repairCommit=$Commit; deliveredMainCommit=$afterCommit; deliveryState=if ($pushExitCode -eq 0) { 'delivered' } else { 'delivered-concurrently' }; branch=$targetBranch; commit=$Commit; deliveredCommit=$afterCommit; pushRef=$pushRef; verifiedAtUtc=[DateTime]::UtcNow.ToString('o') }
    }
    finally { [Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT', $previousTerminalPrompt, 'Process') }
}
