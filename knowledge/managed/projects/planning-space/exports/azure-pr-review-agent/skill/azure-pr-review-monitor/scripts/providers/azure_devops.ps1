function Get-AzureCliPath {
    param([Parameter(Mandatory)] $Profile)
    $path = Find-AgentExecutable -Names @('az.cmd', 'az.exe', 'az') -ConfiguredPath ([string]$Profile.cliPath)
    if (-not $path) { throw "Azure CLI was not found for credential profile '$($Profile.id)'." }
    return $path
}

function Invoke-AzureJson {
    param([Parameter(Mandatory)] $Profile, [Parameter(Mandatory)][string[]] $Arguments)
    $path = Get-AzureCliPath -Profile $Profile
    $environment = Get-ProfileEnvironment -Profile $Profile
    return Invoke-AgentJson -FilePath $path -Arguments ($Arguments + @('--output', 'json')) -Environment $environment
}

function Test-AzureProviderAccess {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile)
    [void](Invoke-AzureJson -Profile $Profile -Arguments @('repos', 'show', '--organization', [string]$Repository.organizationUrl, '--project', [string]$Repository.project, '--repository', [string]$Repository.repository))
    return "Azure DevOps access OK: $($Repository.project)/$($Repository.repository)"
}

function Get-AzureProviderPullRequests {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile)
    $result = Invoke-AzureJson -Profile $Profile -Arguments @(
        'repos', 'pr', 'list', '--organization', [string]$Repository.organizationUrl,
        '--project', [string]$Repository.project, '--repository', [string]$Repository.repository,
        '--reviewer', [string]$Repository.reviewer, '--status', 'active'
    )
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($pr in @($result)) {
        if (-not $pr) { continue }
        $iterationsResult = Invoke-AzureJson -Profile $Profile -Arguments @(
            'devops', 'invoke', '--organization', [string]$Repository.organizationUrl,
            '--area', 'git', '--resource', 'pullRequestIterations', '--route-parameters',
            "project=$($Repository.project)", "repositoryId=$($pr.repository.id)", "pullRequestId=$($pr.pullRequestId)",
            '--api-version', '7.1'
        )
        $iterations = if ($iterationsResult.value) { @($iterationsResult.value) } else { @($iterationsResult) }
        $latest = $iterations | Sort-Object { [int]$_.id } -Descending | Select-Object -First 1
        if (-not $latest) { throw "Azure DevOps returned no iterations for PR $($pr.pullRequestId)." }
        $normalized.Add([pscustomobject][ordered]@{
            provider = 'azure-devops'; repositoryConfigId = [string]$Repository.id
            repositoryId = [string]$pr.repository.id; repositoryName = [string]$pr.repository.name
            repositoryUrl = [string]$Repository.url; cloneUrl = ''
            pullRequestId = [int]$pr.pullRequestId; title = [string]$pr.title
            url = "$($Repository.organizationUrl)/$($Repository.project)/_git/$($pr.repository.name)/pullrequest/$($pr.pullRequestId)"
            authorLogin = [string]$pr.createdBy.uniqueName; authorDisplayName = [string]$pr.createdBy.displayName
            sourceBranch = (([string]$pr.sourceRefName) -replace '^refs/heads/', '')
            targetBranch = (([string]$pr.targetRefName) -replace '^refs/heads/', '')
            sourceCommit = [string]$latest.sourceRefCommit.commitId; targetCommit = [string]$latest.targetRefCommit.commitId
            version = [string]$latest.id; status = [string]$pr.status
        })
    }
    return @($normalized)
}

function Get-AzureProviderPullRequestStatus {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)][int] $PullRequestId)
    $pr = Invoke-AzureJson -Profile $Profile -Arguments @('repos', 'pr', 'show', '--organization', [string]$Repository.organizationUrl, '--id', [string]$PullRequestId)
    return ([string]$pr.status).ToLowerInvariant()
}

function Sync-AzureProviderRepository {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)] $PullRequest, [Parameter(Mandatory)][string] $RepositoryPath)
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
        $metadata = Invoke-AzureJson -Profile $Profile -Arguments @('repos', 'show', '--organization', [string]$Repository.organizationUrl, '--project', [string]$Repository.project, '--repository', [string]$PullRequest.repositoryId)
        if (-not $metadata.remoteUrl) { throw "Azure DevOps did not return a clone URL for '$($Repository.id)'." }
        Invoke-AgentNative -FilePath 'git.exe' -Arguments @('clone', '--no-checkout', [string]$metadata.remoteUrl, $RepositoryPath) | Out-Null
    }
    Invoke-AgentNative -FilePath 'git.exe' -WorkingDirectory $RepositoryPath -Arguments @('config', 'core.longpaths', 'true') | Out-Null
    Invoke-AgentNative -FilePath 'git.exe' -WorkingDirectory $RepositoryPath -Arguments @('fetch', '--prune', 'origin', "+refs/heads/$($PullRequest.sourceBranch):refs/remotes/origin/$($PullRequest.sourceBranch)", "+refs/heads/$($PullRequest.targetBranch):refs/remotes/origin/$($PullRequest.targetBranch)") | Out-Null
}

function Publish-AzureProviderFinding {
    param([Parameter(Mandatory)] $Repository, [Parameter(Mandatory)] $Profile, [Parameter(Mandatory)] $Sidecar, [Parameter(Mandatory)] $Finding, [Parameter(Mandatory)][string] $Comment, [Parameter(Mandatory)][string] $TemporaryPath)
    $pr = Invoke-AzureJson -Profile $Profile -Arguments @('repos', 'pr', 'show', '--organization', [string]$Repository.organizationUrl, '--id', [string]$Sidecar.pullRequestId)
    $body = [ordered]@{ comments = @([ordered]@{ parentCommentId = 0; content = $Comment; commentType = 1 }); status = 1; threadContext = [ordered]@{ filePath = '/' + ([string]$Finding.File).TrimStart('/'); rightFileStart = [ordered]@{ line = [int]$Finding.Line; offset = 1 }; rightFileEnd = [ordered]@{ line = [int]$Finding.Line; offset = 1 } } }
    [IO.File]::WriteAllText($TemporaryPath, ($body | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $response = Invoke-AzureJson -Profile $Profile -Arguments @('devops', 'invoke', '--organization', [string]$Repository.organizationUrl, '--area', 'git', '--resource', 'pullRequestThreads', '--route-parameters', "project=$($pr.repository.project.id)", "repositoryId=$($pr.repository.id)", "pullRequestId=$($Sidecar.pullRequestId)", '--http-method', 'POST', '--in-file', $TemporaryPath, '--api-version', '7.1')
    return [pscustomobject]@{ id = [string]$response.id; url = [string]$Sidecar.pullRequestUrl }
}
