[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Show', 'Validate', 'AddRepository', 'RemoveRepository', 'ConfigureCredential', 'SetReviewPaths', 'SetMcp')]
    [string] $Action = 'Interactive',
    [string] $RepositoryUrl,
    [string] $RepositoryId,
    [string] $Reviewer,
    [string[]] $IncludeAuthors,
    [string[]] $ExcludeAuthors,
    [string] $CredentialProfileId,
    [ValidateSet('azure-cli', 'gh-cli', 'environment')]
    [string] $CredentialMode,
    [string] $CredentialEnvironmentVariable,
    [string] $CliPath,
    [string[]] $SkillPaths,
    [string[]] $PromptPaths,
    [ValidateSet('disabled', 'allowlist')]
    [string] $McpMode,
    [string[]] $McpServers,
    [string] $DataRoot = (Join-Path $env:LOCALAPPDATA 'Codex\azure-pr-review-monitor')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent_config.ps1')
. (Join-Path $PSScriptRoot 'providers\provider_dispatch.ps1')
$configPath = Join-Path $DataRoot 'config.json'
$config = Read-AgentConfig -Path $configPath -Migrate

function Read-RequiredValue {
    param([string] $Prompt, [string] $Current)
    $suffix = if ($Current) { " [$Current]" } else { '' }
    $value = (Read-Host "$Prompt$suffix").Trim()
    if (-not $value) { $value = $Current }
    if (-not $value) { throw "$Prompt is required." }
    return $value
}

function Ensure-ArrayProperty {
    param($Object, [string] $Name)
    if ($null -eq $Object.$Name) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue @() -Force }
}

function Save-Settings {
    Assert-AgentConfig -Config $config
    Write-AgentConfig -Config $config -Path $configPath
    Write-Output "Settings saved to $configPath"
}

function Show-Settings {
    $config | ConvertTo-Json -Depth 12
}

function Get-OrCreateCredentialProfile {
    param([string] $Provider, [string] $ProfileId, [string] $Mode, [string] $EnvironmentVariable, [string] $Path)
    if (-not $ProfileId) { $ProfileId = if ($Provider -eq 'github') { 'github-default' } else { 'azure-default' } }
    $existing = @($config.credentialProfiles | Where-Object { $_.id -eq $ProfileId }) | Select-Object -First 1
    if ($existing) {
        if ($Mode) { $existing.mode = $Mode }
        if ($EnvironmentVariable) { $existing.environmentVariable = $EnvironmentVariable }
        if ($Path) { $existing.cliPath = $Path }
        return $existing
    }
    if (-not $Mode) { $Mode = if ($Provider -eq 'github') { 'gh-cli' } else { 'azure-cli' } }
    if (-not $EnvironmentVariable) { $EnvironmentVariable = if ($Provider -eq 'github') { 'GH_TOKEN' } else { 'AZURE_DEVOPS_EXT_PAT' } }
    $profile = [pscustomobject][ordered]@{ id = $ProfileId; provider = $Provider; mode = $Mode; cliPath = $Path; environmentVariable = $EnvironmentVariable }
    $config.credentialProfiles = @($config.credentialProfiles) + @($profile)
    return $profile
}

if ($Action -eq 'Interactive') {
    Write-Host 'PR Review Agent settings'
    Write-Host '[1] Add repository  [2] Validate  [3] MCP policy  [4] Show settings'
    $choice = (Read-Host 'Select action').Trim()
    $Action = switch ($choice) { '1' { 'AddRepository' } '2' { 'Validate' } '3' { 'SetMcp' } '4' { 'Show' } default { throw 'Invalid selection.' } }
}

switch ($Action) {
    'Show' { Show-Settings; exit 0 }
    'AddRepository' {
        if (-not $RepositoryUrl) { $RepositoryUrl = Read-RequiredValue -Prompt 'Repository URL' }
        $descriptor = Get-RepositoryDescriptor -Url $RepositoryUrl
        if (-not $Reviewer) { $Reviewer = Read-RequiredValue -Prompt 'Reviewer identity (Azure email or GitHub login)' }
        if (-not $RepositoryId) { $RepositoryId = ConvertTo-AgentSlug "$($descriptor.provider)-$($descriptor.fullName)" }
        if (@($config.repositories | Where-Object { $_.id -eq $RepositoryId }).Count) { throw "Repository id '$RepositoryId' already exists." }
        $profile = Get-OrCreateCredentialProfile -Provider $descriptor.provider -ProfileId $CredentialProfileId -Mode $CredentialMode -EnvironmentVariable $CredentialEnvironmentVariable -Path $CliPath
        $repository = [pscustomobject][ordered]@{
            id = $RepositoryId; enabled = $true; provider = $descriptor.provider; url = $RepositoryUrl
            organizationUrl = [string]$descriptor.organizationUrl; project = [string]$descriptor.project
            owner = [string]$descriptor.owner; repository = [string]$descriptor.repository
            reviewer = $Reviewer; credentialProfile = [string]$profile.id
            includeAuthors = @($IncludeAuthors | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }); excludeAuthors = @($ExcludeAuthors | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $config.repositories = @($config.repositories) + @($repository)
        Save-Settings
        Write-Output "Added $($descriptor.provider) repository '$RepositoryId'."
        exit 0
    }
    'RemoveRepository' {
        if (-not $RepositoryId) { $RepositoryId = Read-RequiredValue -Prompt 'Repository id' }
        $remaining = @($config.repositories | Where-Object { $_.id -ne $RepositoryId })
        if ($remaining.Count -eq @($config.repositories).Count) { throw "Repository '$RepositoryId' was not found." }
        $config.repositories = $remaining
        Save-Settings
        exit 0
    }
    'ConfigureCredential' {
        if (-not $CredentialProfileId) { $CredentialProfileId = Read-RequiredValue -Prompt 'Credential profile id' }
        $profile = @($config.credentialProfiles | Where-Object { $_.id -eq $CredentialProfileId }) | Select-Object -First 1
        if (-not $profile) { throw "Credential profile '$CredentialProfileId' was not found. Add a repository first." }
        if (-not $CredentialMode) { $CredentialMode = Read-RequiredValue -Prompt 'Mode (azure-cli, gh-cli, environment)' -Current ([string]$profile.mode) }
        $profile.mode = $CredentialMode
        if ($PSBoundParameters.ContainsKey('CliPath')) { $profile.cliPath = $CliPath }
        if ($CredentialMode -eq 'environment') {
            if (-not $CredentialEnvironmentVariable) { $CredentialEnvironmentVariable = Read-RequiredValue -Prompt 'Environment variable name' -Current ([string]$profile.environmentVariable) }
            $profile.environmentVariable = $CredentialEnvironmentVariable
        }
        Save-Settings
        exit 0
    }
    'SetReviewPaths' {
        if ($PSBoundParameters.ContainsKey('SkillPaths')) { $config.review.skillPaths = @($SkillPaths | Where-Object { $_ }) }
        if ($PSBoundParameters.ContainsKey('PromptPaths')) { $config.review.promptPaths = @($PromptPaths | Where-Object { $_ }) }
        Save-Settings
        exit 0
    }
    'SetMcp' {
        if (-not $McpMode) { $McpMode = Read-RequiredValue -Prompt 'MCP mode (disabled or allowlist)' -Current ([string]$config.review.mcp.mode) }
        if ($McpMode -eq 'allowlist' -and -not $PSBoundParameters.ContainsKey('McpServers')) {
            $entered = (Read-Host 'Allowed MCP server names (comma-separated)').Trim()
            $McpServers = @($entered -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $config.review.mcp.mode = $McpMode
        $config.review.mcp.allowedServers = if ($McpMode -eq 'allowlist') { @($McpServers | Where-Object { $_ }) } else { @() }
        Save-Settings
        exit 0
    }
    'Validate' {
        Assert-AgentConfig -Config $config
        $failures = [Collections.Generic.List[string]]::new()
        foreach ($repository in @($config.repositories | Where-Object { $_.enabled })) {
            try {
                $profile = Get-AgentCredentialProfile -Config $config -Repository $repository
                Write-Output (Test-ProviderAccess -Repository $repository -Profile $profile)
            }
            catch { $failures.Add("$($repository.id): $($_.Exception.Message)") }
        }
        $codex = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $codex) { $failures.Add('Codex CLI was not found.') }
        elseif ($config.review.mcp.mode -eq 'allowlist') {
            try {
                $configured = @((& $codex.Source mcp list --json 2>$null | Out-String | ConvertFrom-Json).name)
                foreach ($server in @($config.review.mcp.allowedServers)) {
                    if ($server -notin $configured) { $failures.Add("MCP server '$server' is allowlisted but is not configured in Codex.") }
                }
            }
            catch { $failures.Add("Unable to validate Codex MCP configuration: $($_.Exception.Message)") }
        }
        if ($failures.Count) { throw "Settings validation failed:`n- $($failures -join "`n- ")" }
        Write-Output 'Configuration validation completed successfully.'
        exit 0
    }
}
