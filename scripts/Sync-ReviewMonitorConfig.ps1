[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$dataRoot = Resolve-EcosystemPath -Value ([string]$config.review.monitorDataRoot) -Config $config -CodexHome $CodexHome
$promptRoot = Resolve-EcosystemPath -Value ([string]$config.review.generatedPromptRoot) -Config $config -CodexHome $CodexHome
$reviewSkill = Resolve-EcosystemPath -Value '${REPO_ROOT}/plugins/development-agent-ecosystem/skills/review-against-requirements/SKILL.md' -Config $config -CodexHome $CodexHome
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
New-Item -ItemType Directory -Path $promptRoot -Force | Out-Null

$repositories = foreach ($repository in @($config.repositories)) {
    [pscustomobject][ordered]@{
        id = [string]$repository.id
        enabled = [bool]$repository.enabled
        provider = [string]$repository.provider
        url = [string]$repository.url
        organizationUrl = [string]$repository.organizationUrl
        project = [string]$repository.project
        repository = [string]$repository.repository
        reviewer = [string]$repository.reviewer
        credentialProfile = [string]$repository.credentialProfile
        includeAuthors = @($repository.includeAuthors)
        excludeAuthors = @($repository.excludeAuthors)
    }
}
$derived = [pscustomobject][ordered]@{
    version = 2
    schedule = [pscustomobject][ordered]@{
        pollIntervalMinutes = [int]$config.operation.automate.pollIntervalMinutes
        dailyTime = [string]$config.operation.automate.dailyTime
    }
    review = [pscustomobject][ordered]@{
        excludeSelfAuthored = [bool]$config.review.excludeSelfAuthored
        maxFilesPerReview = [int]$config.review.maxFilesPerReview
        maxDiffCharacters = [int]$config.review.maxDiffCharacters
        skillPaths = @($reviewSkill)
        promptPaths = @($promptRoot)
        mcp = [pscustomobject][ordered]@{
            mode = [string]$config.review.mcp.mode
            allowedServers = @($config.review.mcp.allowedServers)
        }
    }
    credentialProfiles = @($config.credentialProfiles)
    repositories = @($repositories)
}
$path = Join-Path $dataRoot 'config.json'
$temporary = "$path.tmp"
Write-Utf8NoBom -Path $temporary -Content (($derived | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
Move-Item -LiteralPath $temporary -Destination $path -Force
[pscustomobject]@{ DataRoot = $dataRoot; ConfigPath = $path; PromptRoot = $promptRoot }
