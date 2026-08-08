. (Join-Path $PSScriptRoot 'provider_common.ps1')
. (Join-Path $PSScriptRoot 'azure_devops.ps1')
. (Join-Path $PSScriptRoot 'github.ps1')

function Test-ProviderAccess {
    param($Repository, $Profile)
    switch ([string]$Repository.provider) {
        'azure-devops' { Test-AzureProviderAccess -Repository $Repository -Profile $Profile }
        'github' { Test-GitHubProviderAccess -Repository $Repository -Profile $Profile }
        default { throw "Unsupported provider '$($Repository.provider)'." }
    }
}

function Get-ProviderPullRequests {
    param($Repository, $Profile)
    switch ([string]$Repository.provider) {
        'azure-devops' { @(Get-AzureProviderPullRequests -Repository $Repository -Profile $Profile) }
        'github' { @(Get-GitHubProviderPullRequests -Repository $Repository -Profile $Profile) }
        default { throw "Unsupported provider '$($Repository.provider)'." }
    }
}

function Get-ProviderPullRequestStatus {
    param($Repository, $Profile, [int] $PullRequestId)
    switch ([string]$Repository.provider) {
        'azure-devops' { Get-AzureProviderPullRequestStatus -Repository $Repository -Profile $Profile -PullRequestId $PullRequestId }
        'github' { Get-GitHubProviderPullRequestStatus -Repository $Repository -Profile $Profile -PullRequestId $PullRequestId }
        default { throw "Unsupported provider '$($Repository.provider)'." }
    }
}

function Sync-ProviderRepository {
    param($Repository, $Profile, $PullRequest, [string] $RepositoryPath)
    switch ([string]$Repository.provider) {
        'azure-devops' { Sync-AzureProviderRepository -Repository $Repository -Profile $Profile -PullRequest $PullRequest -RepositoryPath $RepositoryPath }
        'github' { Sync-GitHubProviderRepository -Repository $Repository -Profile $Profile -PullRequest $PullRequest -RepositoryPath $RepositoryPath }
        default { throw "Unsupported provider '$($Repository.provider)'." }
    }
}

function Publish-ProviderFinding {
    param($Repository, $Profile, $Sidecar, $Finding, [string] $Comment, [string] $TemporaryPath)
    switch ([string]$Repository.provider) {
        'azure-devops' { Publish-AzureProviderFinding -Repository $Repository -Profile $Profile -Sidecar $Sidecar -Finding $Finding -Comment $Comment -TemporaryPath $TemporaryPath }
        'github' { Publish-GitHubProviderFinding -Repository $Repository -Profile $Profile -Sidecar $Sidecar -Finding $Finding -Comment $Comment -TemporaryPath $TemporaryPath }
        default { throw "Unsupported provider '$($Repository.provider)'." }
    }
}
