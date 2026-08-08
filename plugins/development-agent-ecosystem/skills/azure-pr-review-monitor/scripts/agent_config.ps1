$script:AgentConfigVersion = 2

function Get-AgentDefaultDataRoot {
    Join-Path $env:LOCALAPPDATA 'Codex\azure-pr-review-monitor'
}

function ConvertTo-AgentSlug {
    param([Parameter(Mandatory)][string] $Value)
    $slug = ($Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { throw "Cannot create an id from '$Value'." }
    return $slug
}

function Get-RepositoryDescriptor {
    param([Parameter(Mandatory)][string] $Url)

    $trimmed = $Url.Trim().TrimEnd('/')
    $azure = [regex]::Match($trimmed, '^https://dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)', 'IgnoreCase')
    if (-not $azure.Success) {
        $azure = [regex]::Match($trimmed, '^https://(?<org>[^.]+)\.visualstudio\.com/(?<project>[^/]+)/_git/(?<repo>[^/?#]+)', 'IgnoreCase')
    }
    if ($azure.Success) {
        $organization = $azure.Groups['org'].Value
        $project = [Uri]::UnescapeDataString($azure.Groups['project'].Value)
        $repository = [Uri]::UnescapeDataString($azure.Groups['repo'].Value) -replace '\.git$', ''
        return [pscustomobject][ordered]@{
            provider = 'azure-devops'
            host = 'dev.azure.com'
            organizationUrl = "https://dev.azure.com/$organization"
            project = $project
            owner = ''
            repository = $repository
            fullName = "$project/$repository"
        }
    }

    $github = [regex]::Match($trimmed, '^(?:https://|ssh://git@|git@)(?<host>[^/:]+)(?::|/)(?<owner>[^/]+)/(?<repo>[^/?#]+)', 'IgnoreCase')
    if ($github.Success) {
        $hostName = $github.Groups['host'].Value
        $owner = [Uri]::UnescapeDataString($github.Groups['owner'].Value)
        $repository = ([Uri]::UnescapeDataString($github.Groups['repo'].Value) -replace '\.git$', '')
        return [pscustomobject][ordered]@{
            provider = 'github'
            host = $hostName
            organizationUrl = ''
            project = ''
            owner = $owner
            repository = $repository
            fullName = "$owner/$repository"
        }
    }

    throw "Unsupported repository URL: $Url. Expected an Azure DevOps or GitHub repository URL."
}

function New-AgentDefaultConfig {
    [pscustomobject][ordered]@{
        version = $script:AgentConfigVersion
        schedule = [pscustomobject][ordered]@{ pollIntervalMinutes = 60; dailyTime = '11:00' }
        review = [pscustomobject][ordered]@{
            excludeSelfAuthored = $true
            maxFilesPerReview = 80
            maxDiffCharacters = 500000
            skillPaths = @()
            promptPaths = @()
            mcp = [pscustomobject][ordered]@{ mode = 'disabled'; allowedServers = @() }
        }
        credentialProfiles = @()
        repositories = @()
    }
}

function Convert-LegacyAgentConfig {
    param([Parameter(Mandatory)] $Legacy)

    $config = New-AgentDefaultConfig
    if ($Legacy.pollIntervalMinutes) { $config.schedule.pollIntervalMinutes = [int]$Legacy.pollIntervalMinutes }
    if ($Legacy.dailyTime) { $config.schedule.dailyTime = [string]$Legacy.dailyTime }
    if ($null -ne $Legacy.excludeSelfAuthored) { $config.review.excludeSelfAuthored = [bool]$Legacy.excludeSelfAuthored }
    $config.review.skillPaths = @($Legacy.reviewSkillPaths | Where-Object { $_ })
    $config.review.promptPaths = @($Legacy.reviewPromptPaths | Where-Object { $_ })

    if ($Legacy.repositoryUrl) {
        $descriptor = Get-RepositoryDescriptor -Url ([string]$Legacy.repositoryUrl)
        $profileId = 'azure-default'
        $config.credentialProfiles = @([pscustomobject][ordered]@{
            id = $profileId
            provider = 'azure-devops'
            mode = 'azure-cli'
            cliPath = [string]$Legacy.azPath
            environmentVariable = 'AZURE_DEVOPS_EXT_PAT'
        })
        $config.repositories = @([pscustomobject][ordered]@{
            id = ConvertTo-AgentSlug "azure-$($descriptor.fullName)"
            enabled = $true
            provider = 'azure-devops'
            url = [string]$Legacy.repositoryUrl
            organizationUrl = if ($Legacy.organizationUrl) { [string]$Legacy.organizationUrl } else { $descriptor.organizationUrl }
            project = if ($Legacy.project) { [string]$Legacy.project } else { $descriptor.project }
            repository = if ($Legacy.repository) { [string]$Legacy.repository } else { $descriptor.repository }
            reviewer = [string]$Legacy.reviewer
            credentialProfile = $profileId
            includeAuthors = @($Legacy.includeAuthors | Where-Object { $_ })
            excludeAuthors = @($Legacy.excludeAuthors | Where-Object { $_ })
        })
    }
    return $config
}

function Read-AgentConfig {
    param(
        [string] $Path = (Join-Path (Get-AgentDefaultDataRoot) 'config.json'),
        [switch] $Migrate
    )

    if (-not (Test-Path -LiteralPath $Path)) { return New-AgentDefaultConfig }
    $raw = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ([int]$raw.version -eq $script:AgentConfigVersion) { return $raw }
    $converted = Convert-LegacyAgentConfig -Legacy $raw
    if ($Migrate) { Write-AgentConfig -Config $converted -Path $Path }
    return $converted
}

function Write-AgentConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [string] $Path = (Join-Path (Get-AgentDefaultDataRoot) 'config.json')
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, ($Config | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-AgentCredentialProfile {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Repository)
    $profile = @($Config.credentialProfiles | Where-Object { $_.id -eq $Repository.credentialProfile }) | Select-Object -First 1
    if (-not $profile) { throw "Credential profile '$($Repository.credentialProfile)' was not found for repository '$($Repository.id)'." }
    if ($profile.provider -ne $Repository.provider) { throw "Credential profile '$($profile.id)' does not match provider '$($Repository.provider)'." }
    return $profile
}

function Assert-AgentConfig {
    param([Parameter(Mandatory)] $Config)
    if ([int]$Config.version -ne $script:AgentConfigVersion) { throw "Unsupported config version '$($Config.version)'." }
    $repositoryIds = @{}
    foreach ($repository in @($Config.repositories)) {
        if (-not $repository.id -or $repositoryIds.ContainsKey([string]$repository.id)) { throw 'Every repository must have a unique non-empty id.' }
        $repositoryIds[[string]$repository.id] = $true
        if ($repository.provider -notin @('azure-devops', 'github')) { throw "Unsupported provider '$($repository.provider)'." }
        $profile = Get-AgentCredentialProfile -Config $Config -Repository $repository
        if ($repository.provider -eq 'azure-devops' -and $profile.mode -notin @('azure-cli','environment')) { throw "Azure DevOps profile '$($profile.id)' must use azure-cli or environment mode." }
        if ($repository.provider -eq 'github' -and $profile.mode -notin @('gh-cli','environment')) { throw "GitHub profile '$($profile.id)' must use gh-cli or environment mode." }
        $descriptor = Get-RepositoryDescriptor -Url ([string]$repository.url)
        if ($descriptor.provider -ne $repository.provider) { throw "Repository '$($repository.id)' URL does not match its provider." }
        if (-not $repository.reviewer) { throw "Repository '$($repository.id)' requires a reviewer identity." }
    }
    $mcpMode = [string]$Config.review.mcp.mode
    if ($mcpMode -notin @('disabled', 'allowlist')) { throw "MCP mode must be 'disabled' or 'allowlist'." }
    if ([int]$Config.review.maxFilesPerReview -lt 1 -or [int]$Config.review.maxFilesPerReview -gt 500) { throw 'Review maxFilesPerReview must be between 1 and 500.' }
    if ([int]$Config.review.maxDiffCharacters -lt 10000 -or [int]$Config.review.maxDiffCharacters -gt 1500000) { throw 'Review maxDiffCharacters must be between 10000 and 1500000.' }
}
