function Get-GitHubCliPath {
    param([Parameter(Mandatory)] $Profile)
    $path = Find-AgentExecutable -Names @('gh.exe', 'gh') -ConfiguredPath ([string]$Profile.cliPath)
    if (-not $path) { throw "GitHub CLI was not found for credential profile '$($Profile.id)'. Install it with: winget install --id GitHub.cli" }
    return $path
}

function Get-GitHubRepositorySpec {
    param([Parameter(Mandatory)] $Descriptor)
    if ($Descriptor.host -eq 'github.com') { return [string]$Descriptor.fullName }
    return "$($Descriptor.host)/$($Descriptor.fullName)"
}

function Invoke-GitHubJson {
    param([Parameter(Mandatory)] $Profile, [Parameter(Mandatory)][string[]] $Arguments)
    return Invoke-AgentJson -FilePath (Get-GitHubCliPath -Profile $Profile) -Arguments $Arguments -Environment (Get-ProfileEnvironment -Profile $Profile)
}

function Test-GitHubProviderAccess {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile)
    $descriptor = Get-RepositoryDescriptor -Url ([string]$Repository.url)
    [void](Invoke-GitHubJson -Profile $Profile -Arguments @('repo', 'view', (Get-GitHubRepositorySpec $descriptor), '--json', 'nameWithOwner'))
    return "GitHub access OK: $($descriptor.fullName)"
}

function Get-GitHubProviderPullRequests {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile)
    $descriptor = Get-RepositoryDescriptor -Url ([string]$Repository.url)
    $reviewer = if ($Repository.reviewer) { [string]$Repository.reviewer } else { '@me' }
    $result = Invoke-GitHubJson -Profile $Profile -Arguments @('pr', 'list', '--repo', (Get-GitHubRepositorySpec $descriptor), '--state', 'open', '--search', "review-requested:$reviewer", '--limit', '200', '--json', 'number,title,author,headRefName,headRefOid,baseRefName,baseRefOid,url,state,updatedAt')
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($pr in @($result)) {
        if (-not $pr) { continue }
        $normalized.Add([pscustomobject][ordered]@{
            provider = 'github'; repositoryConfigId = [string]$Repository.id
            repositoryId = [string]$descriptor.fullName; repositoryName = [string]$descriptor.repository
            repositoryUrl = [string]$Repository.url; cloneUrl = "https://$($descriptor.host)/$($descriptor.fullName).git"
            pullRequestId = [int]$pr.number; title = [string]$pr.title; url = [string]$pr.url
            authorLogin = [string]$pr.author.login; authorDisplayName = [string]$pr.author.login
            sourceBranch = [string]$pr.headRefName; targetBranch = [string]$pr.baseRefName
            sourceCommit = [string]$pr.headRefOid; targetCommit = [string]$pr.baseRefOid
            version = [string]$pr.headRefOid; status = ([string]$pr.state).ToLowerInvariant()
        })
    }
    return @($normalized)
}

function Get-GitHubProviderPullRequestStatus {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)][int] $PullRequestId)
    $descriptor = Get-RepositoryDescriptor -Url ([string]$Repository.url)
    $pr = Invoke-GitHubJson -Profile $Profile -Arguments @('pr', 'view', [string]$PullRequestId, '--repo', (Get-GitHubRepositorySpec $descriptor), '--json', 'state')
    return ([string]$pr.state).ToLowerInvariant()
}

function Sync-GitHubProviderRepository {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)] $PullRequest, [Parameter(Mandatory)][string] $RepositoryPath)
    $descriptor = Get-RepositoryDescriptor -Url ([string]$Repository.url)
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
        Invoke-AgentNative -FilePath (Get-GitHubCliPath -Profile $Profile) -Arguments @('repo', 'clone', (Get-GitHubRepositorySpec $descriptor), $RepositoryPath, '--', '--no-checkout') -Environment (Get-ProfileEnvironment -Profile $Profile) | Out-Null
    }
    Invoke-AgentNative -FilePath 'git.exe' -WorkingDirectory $RepositoryPath -Arguments @('config', 'core.longpaths', 'true') | Out-Null
    Invoke-AgentNative -FilePath 'git.exe' -WorkingDirectory $RepositoryPath -Arguments @('fetch', '--prune', 'origin', "+refs/pull/$($PullRequest.pullRequestId)/head:refs/remotes/origin/pr/$($PullRequest.pullRequestId)", "+refs/heads/$($PullRequest.targetBranch):refs/remotes/origin/$($PullRequest.targetBranch)") | Out-Null
}

function Publish-GitHubProviderFinding {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)] $Sidecar, [Parameter(Mandatory)] $Finding, [Parameter(Mandatory)][string] $Comment, [Parameter(Mandatory)][string] $TemporaryPath)
    $descriptor = Get-RepositoryDescriptor -Url ([string]$Repository.url)
    $body = [ordered]@{ body = $Comment; commit_id = [string]$Sidecar.sourceCommit; path = [string]$Finding.File; line = [int]$Finding.Line; side = 'RIGHT' }
    [IO.File]::WriteAllText($TemporaryPath, ($body | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $response = Invoke-GitHubJson -Profile $Profile -Arguments @('api', '--hostname', $descriptor.host, '--method', 'POST', "repos/$($descriptor.fullName)/pulls/$($Sidecar.pullRequestId)/comments", '--input', $TemporaryPath)
    return [pscustomobject]@{ id = [string]$response.id; url = [string]$response.html_url }
}
