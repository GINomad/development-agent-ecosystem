Set-StrictMode -Version Latest

function Get-EcosystemRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-DefaultCodexHome {
    param([string] $Override)
    if ($Override) { return [IO.Path]::GetFullPath($Override) }
    if ($env:CODEX_HOME) { return [IO.Path]::GetFullPath($env:CODEX_HOME) }
    return [IO.Path]::GetFullPath((Join-Path $HOME '.codex'))
}

function Expand-EcosystemValue {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $CodexHome,
        [string] $StateRoot
    )
    $expanded = $Value
    $expanded = $expanded.Replace('${REPO_ROOT}', $RepositoryRoot)
    $expanded = $expanded.Replace('${CODEX_HOME}', $CodexHome)
    $expanded = $expanded.Replace('${LOCALAPPDATA}', [string]$env:LOCALAPPDATA)
    if ($StateRoot) { $expanded = $expanded.Replace('${STATE_ROOT}', $StateRoot) }
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

function Get-EcosystemConfig {
    param(
        [string] $ConfigPath = (Join-Path (Get-EcosystemRoot) 'config\agents.json'),
        [string] $CodexHome
    )
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file was not found: $ConfigPath"
    }
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { throw "Configuration is not valid JSON: $($_.Exception.Message)" }
    Assert-EcosystemConfig -Config $config -ConfigPath $ConfigPath -CodexHome $CodexHome
    return $config
}

function Get-EcosystemStateRoot {
    param([Parameter(Mandatory)] $Config, [string] $CodexHome)
    $repositoryRoot = Get-EcosystemRoot
    $resolvedCodexHome = Get-DefaultCodexHome -Override $CodexHome
    $value = Expand-EcosystemValue -Value ([string]$Config.runtime.stateRoot) -RepositoryRoot $repositoryRoot -CodexHome $resolvedCodexHome
    return [IO.Path]::GetFullPath(($value -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function Resolve-EcosystemPath {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)] $Config,
        [string] $CodexHome
    )
    $repositoryRoot = Get-EcosystemRoot
    $resolvedCodexHome = Get-DefaultCodexHome -Override $CodexHome
    $stateRoot = Get-EcosystemStateRoot -Config $Config -CodexHome $resolvedCodexHome
    $expanded = Expand-EcosystemValue -Value $Value -RepositoryRoot $repositoryRoot -CodexHome $resolvedCodexHome -StateRoot $stateRoot
    return [IO.Path]::GetFullPath(($expanded -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function Assert-EcosystemConfig {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string] $ConfigPath,
        [string] $CodexHome
    )
    foreach ($property in @('schemaVersion','namespace','runtime','operation','ui','health','review','credentialProfiles','repositories','taskSources','knowledge','gates','agents')) {
        if (-not $Config.PSObject.Properties[$property]) { throw "Missing required configuration property '$property'." }
    }
    if ([string]$Config.operation.mode -notin @('manual','automate')) { throw "operation.mode must be 'manual' or 'automate'." }
    if ([string]$Config.ui.listenAddress -ne '127.0.0.1') { throw 'The dashboard must listen on 127.0.0.1.' }
    if ([int]$Config.ui.port -lt 1024 -or [int]$Config.ui.port -gt 65535) { throw 'ui.port must be between 1024 and 65535.' }
    if ([int]$Config.ui.taskRefreshSeconds -lt 2 -or [int]$Config.ui.taskRefreshSeconds -gt 300) { throw 'ui.taskRefreshSeconds must be between 2 and 300.' }
    if ([int]$Config.runtime.executionGuard.maxIdenticalFailures -ne 3) { throw 'runtime.executionGuard.maxIdenticalFailures must be exactly 3.' }
    if ([int]$Config.runtime.executionGuard.maxRunMinutes -lt 5 -or [int]$Config.runtime.executionGuard.maxRunMinutes -gt 1440) { throw 'runtime.executionGuard.maxRunMinutes is outside the supported range.' }
    if (-not [bool]$Config.runtime.elevatedFallback.requiresDashboardApproval -or [string]$Config.runtime.elevatedFallback.sandboxMode -ne 'danger-full-access') { throw 'Workflow elevated fallback must require explicit dashboard approval.' }
    if (-not [bool]$Config.runtime.elevatedFallback.installCompatibleAgentsOnDetection -or [string]$Config.runtime.elevatedFallback.agentProfileSuffix -notmatch '^_[a-z0-9_]+$') { throw 'Host-compatible agent profile configuration is invalid.' }
    $compatibilityPrompt = Resolve-EcosystemPath -Value ([string]$Config.runtime.elevatedFallback.compatibilityPromptPath) -Config $Config -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $compatibilityPrompt -PathType Leaf)) { throw "Host-compatible agent prompt is missing: $compatibilityPrompt" }
    if ([string]$Config.health.repairMode -ne 'safe-deterministic-only') { throw 'health.repairMode must be safe-deterministic-only.' }
    if ([string]$Config.health.dashboardHealthUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/health$') { throw 'health.dashboardHealthUrl must use the loopback health endpoint.' }
    if ([bool]$Config.health.automaticRecovery.allowProductCodeChanges) { throw 'Health automatic recovery must not modify product code.' }
    if ([bool]$Config.health.automaticRecovery.allowExternalWrites) { throw 'Health automatic recovery must not perform external writes.' }
    if ([string]$Config.health.automaticRecovery.sandboxMode -ne 'workspace-write') { throw 'Automatic Health recovery must use workspace-write.' }
    if ([string]$Config.health.automaticRecovery.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$Config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Elevated Health recovery must require explicit dashboard approval.' }
    if ([int]$Config.health.automaticRecovery.elevatedFallback.maxAttemptsPerFailureSignature -lt 0 -or [int]$Config.health.automaticRecovery.elevatedFallback.maxAttemptsPerFailureSignature -gt 1) { throw 'Elevated Health recovery allows at most one attempt per failure signature.' }
    if ([int]$Config.health.automaticRecovery.maxAttemptsPerFailureSignature -lt 0 -or [int]$Config.health.automaticRecovery.maxAttemptsPerFailureSignature -gt 3) { throw 'Health automatic recovery attempts must be between 0 and 3.' }

    $profileIds = @{}
    foreach ($profile in @($Config.credentialProfiles)) {
        if (-not $profile.id -or $profileIds.ContainsKey([string]$profile.id)) { throw 'Credential profile IDs must be unique and non-empty.' }
        $profileIds[[string]$profile.id] = $profile
        if ($profile.PSObject.Properties['token'] -or $profile.PSObject.Properties['password'] -or $profile.PSObject.Properties['secret']) {
            throw "Credential profile '$($profile.id)' contains a forbidden plaintext credential field."
        }
    }
    $repositoryIds = @{}
    foreach ($repository in @($Config.repositories)) {
        if (-not $repository.id -or $repositoryIds.ContainsKey([string]$repository.id)) { throw 'Repository IDs must be unique and non-empty.' }
        $repositoryIds[[string]$repository.id] = $true
        if (-not $profileIds.ContainsKey([string]$repository.credentialProfile)) {
            throw "Repository '$($repository.id)' references missing credential profile '$($repository.credentialProfile)'."
        }
        if ($repository.provider -ne $profileIds[[string]$repository.credentialProfile].provider) {
            throw "Repository '$($repository.id)' and credential profile '$($repository.credentialProfile)' use different providers."
        }
    }

    $agentIds = @{}
    $agentNames = @{}
    foreach ($agent in @($Config.agents)) {
        if (-not $agent.id -or $agentIds.ContainsKey([string]$agent.id)) { throw 'Agent IDs must be unique and non-empty.' }
        if (-not $agent.name -or $agentNames.ContainsKey([string]$agent.name)) { throw 'Agent names must be unique and non-empty.' }
        $agentIds[[string]$agent.id] = $true
        $agentNames[[string]$agent.name] = $true
    }
    foreach ($requiredId in @('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor')) {
        if (-not $agentIds.ContainsKey($requiredId)) { throw "Required agent '$requiredId' is missing." }
    }
    foreach ($agent in @($Config.agents)) {
        foreach ($handoff in @($agent.handoffs)) {
            if (-not $agentIds.ContainsKey([string]$handoff)) { throw "Agent '$($agent.id)' references missing handoff '$handoff'." }
        }
        foreach ($pathValue in @($agent.promptPaths) + @($agent.skillPaths)) {
            $resolved = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $Config -CodexHome $CodexHome
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "Agent '$($agent.id)' references a missing file: $resolved"
            }
        }
    }
}

function ConvertTo-TomlString {
    param([AllowEmptyString()][string] $Value)
    $slash = [string][char]92
    $quote = [string][char]34
    $escaped = $Value.Replace($slash, $slash + $slash).Replace($quote, $slash + $quote)
    $escaped = $escaped.Replace("`r", $slash + 'r').Replace("`n", $slash + 'n').Replace("`t", $slash + 't')
    return $quote + $escaped + $quote
}

function New-AgentToml {
    param(
        [Parameter(Mandatory)] $Agent,
        [Parameter(Mandatory)] $Config,
        [string] $CodexHome
    )
    $promptSections = [Collections.Generic.List[string]]::new()
    foreach ($pathValue in @($Agent.promptPaths)) {
        $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $Config -CodexHome $CodexHome
        $promptSections.Add("Source: $path`n$((Get-Content -LiteralPath $path -Raw).Trim())")
    }
    $handoffs = @($Agent.handoffs) -join ', '
    $artifacts = @($Agent.requiredArtifacts) -join ', '
    $promptSections.Add("Configured handoffs: $handoffs`nRequired artifacts: $artifacts")

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by development-agent-ecosystem. Edit config/agents.json and prompt files, not this file.')
    $lines.Add("name = $(ConvertTo-TomlString ([string]$Agent.name))")
    $lines.Add("description = $(ConvertTo-TomlString ([string]$Agent.description))")
    if ($Agent.PSObject.Properties['model'] -and $Agent.model) {
        $lines.Add("model = $(ConvertTo-TomlString ([string]$Agent.model))")
    }
    $lines.Add("model_reasoning_effort = $(ConvertTo-TomlString ([string]$Agent.reasoningEffort))")
    $lines.Add("sandbox_mode = $(ConvertTo-TomlString ([string]$Agent.sandboxMode))")
    $lines.Add("developer_instructions = $(ConvertTo-TomlString ($promptSections -join "`n`n"))")
    foreach ($pathValue in @($Agent.skillPaths)) {
        $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $Config -CodexHome $CodexHome
        $lines.Add('')
        $lines.Add('[[skills.config]]')
        $lines.Add("path = $(ConvertTo-TomlString $path)")
        $lines.Add('enabled = true')
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Get-EcosystemRoot, Get-DefaultCodexHome, Expand-EcosystemValue, Get-EcosystemConfig, Get-EcosystemStateRoot, Resolve-EcosystemPath, Assert-EcosystemConfig, ConvertTo-TomlString, New-AgentToml, Write-Utf8NoBom
