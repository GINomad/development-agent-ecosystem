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

function Resolve-CodexCliPath {
    $command = Get-Command codex.exe, codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return [IO.Path]::GetFullPath([string]$command.Source) }

    $extensionRoots = @(
        (Join-Path ([string]$env:USERPROFILE) '.vscode\extensions'),
        (Join-Path ([string]$env:USERPROFILE) '.vscode-insiders\extensions')
    )
    foreach ($root in $extensionRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates = @(Get-ChildItem -Path (Join-Path $root 'openai.chatgpt-*-win32-*\bin\*\codex.exe') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        if ($candidates.Count) { return [IO.Path]::GetFullPath([string]$candidates[0].FullName) }
    }
    return $null
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
    foreach ($property in @('schemaVersion','namespace','runtime','operation','workflow','modelRouting','ui','health','review','pipeline','credentialProfiles','repositories','taskSources','knowledge','gates','agents')) {
        if (-not $Config.PSObject.Properties[$property]) { throw "Missing required configuration property '$property'." }
    }
    if ([string]$Config.operation.mode -notin @('manual','automate')) { throw "operation.mode must be 'manual' or 'automate'." }
    if (-not [bool]$Config.workflow.orchestration.enabled -or [string]$Config.workflow.orchestration.agentId -ne 'orchestrator') { throw 'workflow.orchestration must enable the configured orchestrator.' }
    if (-not [bool]$Config.workflow.orchestration.outcomeDrivenTransitions -or [string]$Config.workflow.orchestration.transitionEntryPoint -ne '${REPO_ROOT}/scripts/Invoke-OrchestratorContinuation.ps1') { throw 'Every successful role outcome must return through the canonical Orchestrator transition entry point.' }
    if (-not [bool]$Config.workflow.orchestration.routeUntargetedComments -or -not [bool]$Config.workflow.orchestration.preserveExplicitTargets) { throw 'Workflow intake must route untargeted comments and preserve explicit targets.' }
    if (-not [bool]$Config.workflow.orchestration.forwardOutOfScopeComments -or -not [bool]$Config.workflow.orchestration.autoDispatchForwardedComments) { throw 'Out-of-scope agent comments must be forwarded to and automatically dispatched through Orchestrator.' }
    if ([IO.Path]::GetFileName([string]$Config.workflow.orchestration.routingArtifact) -ne [string]$Config.workflow.orchestration.routingArtifact) { throw 'workflow.orchestration.routingArtifact must be a direct task artifact.' }
    if (-not [bool]$Config.workflow.workspaceScheduling.enabled -or [int]$Config.workflow.workspaceScheduling.maxActiveTasks -lt 2 -or -not [bool]$Config.workflow.workspaceScheduling.queueWhenBusy) { throw 'Workspace scheduling must allow at least two independently leased tasks.' }
    if ([string]::IsNullOrWhiteSpace([string]$Config.workflow.workspaceScheduling.workspaceRoot)) { throw 'Workspace scheduling requires a clone workspace root.' }
    if ([int]$Config.workflow.workspaceScheduling.maxActiveAgentsPerTask -ne 1) { throw 'Workspace scheduling currently supports exactly one active agent per task.' }
    if ([int]$Config.workflow.workspaceScheduling.lockTimeoutSeconds -lt 5 -or [int]$Config.workflow.workspaceScheduling.lockTimeoutSeconds -gt 120) { throw 'Workspace scheduling lock timeout is outside the supported range.' }
    $leaseHeartbeatSeconds = [int]$Config.workflow.workspaceScheduling.leaseHeartbeatSeconds
    $staleLeaseGraceSeconds = [int]$Config.workflow.workspaceScheduling.staleLeaseGraceSeconds
    if ($leaseHeartbeatSeconds -lt 5 -or $leaseHeartbeatSeconds -gt 300) { throw 'Workspace lease heartbeat interval is outside the supported range.' }
    if ($staleLeaseGraceSeconds -lt ($leaseHeartbeatSeconds * 3) -or $staleLeaseGraceSeconds -gt 3600) { throw 'Workspace stale lease grace must be at least three heartbeat intervals and no more than one hour.' }
    if ([int]$Config.workflow.automaticContinuation.maxChainSteps -lt 1 -or [int]$Config.workflow.automaticContinuation.maxChainSteps -gt 32) { throw 'workflow.automaticContinuation.maxChainSteps is outside the supported range.' }
    if ([int]$Config.workflow.automaticContinuation.maxTransitionRepeats -ne 3) { throw 'workflow.automaticContinuation.maxTransitionRepeats must be exactly 3.' }
    if ([int]$Config.workflow.automaticContinuation.recoveryGraceSeconds -lt 30 -or [int]$Config.workflow.automaticContinuation.recoveryGraceSeconds -gt 600) { throw 'workflow.automaticContinuation.recoveryGraceSeconds is outside the supported range.' }
    if ([int]$Config.workflow.automaticContinuation.recoveryPollIntervalMinutes -lt 1 -or [int]$Config.workflow.automaticContinuation.recoveryPollIntervalMinutes -gt 60) { throw 'workflow.automaticContinuation.recoveryPollIntervalMinutes is outside the supported range.' }
    if ((@($Config.workflow.automaticContinuation.orderedAgentIds) -join '|') -ne 'requirements_analyst|developer|reviewer|pipeline_monitor|knowledge_keeper') { throw 'The automatic continuation order is invalid.' }
    if ([string]$Config.ui.listenAddress -ne '127.0.0.1') { throw 'The dashboard must listen on 127.0.0.1.' }
    if ([int]$Config.ui.port -lt 1024 -or [int]$Config.ui.port -gt 65535) { throw 'ui.port must be between 1024 and 65535.' }
    if ([int]$Config.ui.taskRefreshSeconds -lt 2 -or [int]$Config.ui.taskRefreshSeconds -gt 300) { throw 'ui.taskRefreshSeconds must be between 2 and 300.' }
    if ([int]$Config.ui.agentLogRefreshSeconds -lt 2 -or [int]$Config.ui.agentLogRefreshSeconds -gt 300) { throw 'ui.agentLogRefreshSeconds must be between 2 and 300.' }
    if ([int]$Config.runtime.executionGuard.maxIdenticalFailures -ne 3) { throw 'runtime.executionGuard.maxIdenticalFailures must be exactly 3.' }
    if ([int]$Config.runtime.executionGuard.maxRunMinutes -lt 5 -or [int]$Config.runtime.executionGuard.maxRunMinutes -gt 1440) { throw 'runtime.executionGuard.maxRunMinutes is outside the supported range.' }
    if (-not [bool]$Config.runtime.elevatedFallback.useByDefault -or [bool]$Config.runtime.elevatedFallback.requiresDashboardApproval -or [string]$Config.runtime.elevatedFallback.sandboxMode -ne 'danger-full-access') { throw 'Workflow host-compatible execution must be enabled by default under the standing user authorization.' }
    if (-not [bool]$Config.health.automaticRecovery.allowEcosystemSourceChanges -or -not [bool]$Config.health.automaticRecovery.preserveDirtyWorktreeChanges -or -not [bool]$Config.health.automaticRecovery.commitVerifiedRepairs -or -not [bool]$Config.health.automaticRecovery.pushVerifiedRepairs) { throw 'Health recovery must preserve an existing dirty baseline, permit validated ecosystem-only source changes, and deliver the verified commit chain.' }
    if ([string]$Config.health.automaticRecovery.pushRemote -ne 'origin' -or [string]$Config.health.automaticRecovery.pushRemoteUrl -ne 'https://github.com/GINomad/development-agent-ecosystem.git') { throw 'Health recovery push destination must be the exact canonical ecosystem origin.' }
    if ([string]$Config.health.automaticRecovery.repairBranchPrefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$') { throw 'Health recovery repair branch prefix is invalid.' }
    if ([bool]$Config.health.automaticRecovery.allowProductCodeChanges -or [bool]$Config.health.automaticRecovery.allowExternalWrites) { throw 'Health recovery must not modify product repositories or external systems.' }
    if (-not [bool]$Config.runtime.elevatedFallback.installCompatibleAgentsOnDetection -or [string]$Config.runtime.elevatedFallback.agentProfileSuffix -notmatch '^_[a-z0-9_]+$') { throw 'Host-compatible agent profile configuration is invalid.' }
    if ([string]$Config.runtime.elevatedFallback.launchStrategy -ne 'in-process-runspace') { throw 'Host-compatible workflows must use the in-process-runspace launch strategy.' }
    if (-not [bool]$Config.modelRouting.enabled -or [string]$Config.modelRouting.artifactName -ne 'model-routing.json') { throw 'Deterministic model routing must be enabled with the canonical task artifact.' }
    if ([int]$Config.modelRouting.largeEvidenceCharacters -ge [int]$Config.modelRouting.maxEvidenceCharacters) { throw 'modelRouting.largeEvidenceCharacters must be lower than maxEvidenceCharacters.' }
    $modelTiers = @($Config.modelRouting.tiers | Sort-Object { [int]$_.rank })
    if ((@($modelTiers | ForEach-Object { [string]$_.id }) -join '|') -ne 'routine|standard|complex|critical' -or (@($modelTiers | ForEach-Object { [string][int]$_.rank }) -join '|') -ne '0|1|2|3') { throw 'Model-routing tiers must define ordered routine, standard, complex, and critical levels.' }
    if (@($modelTiers | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.model) -or [string]$_.reasoningEffort -notin @('low','medium','high','xhigh','max') }).Count) { throw 'Every model-routing tier requires a supported model and reasoning effort.' }
    $compatibilityPrompt = Resolve-EcosystemPath -Value ([string]$Config.runtime.elevatedFallback.compatibilityPromptPath) -Config $Config -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $compatibilityPrompt -PathType Leaf)) { throw "Host-compatible agent prompt is missing: $compatibilityPrompt" }
    if ([string]$Config.health.repairMode -ne 'safe-deterministic-only') { throw 'health.repairMode must be safe-deterministic-only.' }
    if ([string]$Config.health.dashboardHealthUrl -notmatch '^http://127\.0\.0\.1:[0-9]+/health$') { throw 'health.dashboardHealthUrl must use the loopback health endpoint.' }
    if ([string]$Config.knowledge.weeklyReport.localTime -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'knowledge.weeklyReport.localTime must use 24-hour HH:mm format.' }
    if ([string]$Config.knowledge.weeklyReport.dayOfWeek -notin @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')) { throw 'knowledge.weeklyReport.dayOfWeek is invalid.' }
    if ([int]$Config.knowledge.weeklyReport.lookbackDays -lt 1 -or [int]$Config.knowledge.weeklyReport.lookbackDays -gt 31) { throw 'knowledge.weeklyReport.lookbackDays must be between 1 and 31.' }
    $globalStandardsPath = Resolve-EcosystemPath -Value ([string]$Config.knowledge.globalStandardsPath) -Config $Config -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $globalStandardsPath -PathType Leaf)) { throw "Global coding standards are missing: $globalStandardsPath" }
    $globalStandardsRoot = Split-Path -Parent $globalStandardsPath
    $versionedKnowledgeRoots = @($Config.knowledge.versionedRoots | ForEach-Object { Resolve-EcosystemPath -Value ([string]$_) -Config $Config -CodexHome $CodexHome })
    if (@($versionedKnowledgeRoots | Where-Object { $globalStandardsRoot.StartsWith(([IO.Path]::GetFullPath($_).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or $globalStandardsRoot.Equals([IO.Path]::GetFullPath($_), [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { throw 'Global coding standards must be inside a versioned knowledge root.' }
    if ([bool]$Config.health.automaticRecovery.allowProductCodeChanges) { throw 'Health automatic recovery must not modify product code.' }
    if ([bool]$Config.health.automaticRecovery.allowExternalWrites) { throw 'Health automatic recovery must not perform external writes.' }
    if ([string]$Config.health.automaticRecovery.sandboxMode -ne 'workspace-write') { throw 'Automatic Health recovery must use workspace-write.' }
    if ([string]$Config.health.automaticRecovery.elevatedFallback.sandboxMode -ne 'danger-full-access' -or -not [bool]$Config.health.automaticRecovery.elevatedFallback.useByDefault -or [bool]$Config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Host-compatible Health recovery must be enabled by default under the standing user authorization.' }
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
    if ([int]$Config.pipeline.postPush.maxRemediationCycles -lt 1 -or [int]$Config.pipeline.postPush.maxRemediationCycles -gt 3) { throw 'pipeline.postPush.maxRemediationCycles must be between 1 and 3.' }
    if ([bool]$Config.pipeline.delivery.allowForce -or [bool]$Config.pipeline.delivery.allowTags -or [string]$Config.pipeline.delivery.remote -ne 'origin') { throw 'Pipeline delivery permits only a normal branch push to origin.' }
    if (-not [bool]$Config.pipeline.delivery.requireCleanWorktree) { throw 'Pipeline delivery requires a clean worktree.' }
    if ([int]$Config.pipeline.postPush.failureLogTailLines -lt 20 -or [int]$Config.pipeline.postPush.failureLogTailLines -gt 500) { throw 'pipeline.postPush.failureLogTailLines is outside the supported range.' }
    if ([int]$Config.pipeline.postPush.failureLogMaxBytes -lt 4096 -or [int]$Config.pipeline.postPush.failureLogMaxBytes -gt 262144) { throw 'pipeline.postPush.failureLogMaxBytes is outside the supported range.' }
    $pipelineRepositoryIds = @{}
    foreach ($pipelineRepository in @($Config.pipeline.repositories)) {
        $pipelineRepositoryId = [string]$pipelineRepository.repositoryId
        if (-not $repositoryIds.ContainsKey($pipelineRepositoryId)) { throw "Pipeline configuration references unknown repository '$pipelineRepositoryId'." }
        if ($pipelineRepositoryIds.ContainsKey($pipelineRepositoryId)) { throw "Pipeline configuration repeats repository '$pipelineRepositoryId'." }
        $pipelineRepositoryIds[$pipelineRepositoryId] = $true
        if (@($pipelineRepository.autoQueueDefinitionIds) -contains 891) { throw 'Deployment definition 891 must never be auto-queued.' }
        if (-not [bool]$Config.pipeline.postPush.autoQueueApprovedBuilds -and @($pipelineRepository.autoQueueDefinitionIds).Count) { throw 'Auto-queue definition IDs require pipeline.postPush.autoQueueApprovedBuilds=true.' }
        if (@($pipelineRepository.autoQueueDefinitionIds | Select-Object -Unique).Count -ne @($pipelineRepository.autoQueueDefinitionIds).Count) { throw "Pipeline auto-queue sequence for '$pipelineRepositoryId' contains duplicate definition IDs." }
    }
    $monitorSkillRoot = Resolve-EcosystemPath -Value ([string]$Config.pipeline.monitorSkillRoot) -Config $Config -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $monitorSkillRoot -PathType Container)) { throw "Pipeline monitor skill root is missing: $monitorSkillRoot" }

    $agentIds = @{}
    $agentNames = @{}
    foreach ($agent in @($Config.agents)) {
        if (-not $agent.id -or $agentIds.ContainsKey([string]$agent.id)) { throw 'Agent IDs must be unique and non-empty.' }
        if (-not $agent.name -or $agentNames.ContainsKey([string]$agent.name)) { throw 'Agent names must be unique and non-empty.' }
        $agentIds[[string]$agent.id] = $true
        $agentNames[[string]$agent.name] = $true
    }
    foreach ($requiredId in @('orchestrator','knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor','health_check')) {
        if (-not $agentIds.ContainsKey($requiredId)) { throw "Required agent '$requiredId' is missing." }
    }
    $pipelineOwners = [ordered]@{
        monitorAgentId = 'pipeline_monitor'
        productRemediationAgentId = 'developer'
        remediationReviewAgentId = 'reviewer'
        exceptionRoutingAgentId = 'orchestrator'
        ecosystemRecoveryAgentId = 'health_check'
        completionAgentId = 'knowledge_keeper'
    }
    foreach ($property in $pipelineOwners.Keys) {
        $configuredAgentId = [string]$Config.pipeline.ownership.$property
        if ($configuredAgentId -ne [string]$pipelineOwners[$property]) { throw "pipeline.ownership.$property must be '$($pipelineOwners[$property])'." }
        if (-not $agentIds.ContainsKey($configuredAgentId)) { throw "pipeline.ownership.$property references missing agent '$configuredAgentId'." }
    }
    $modelTierById = @{}
    foreach ($tier in $modelTiers) { $modelTierById[[string]$tier.id] = $tier }
    $rolePolicyIds = @{}
    foreach ($policy in @($Config.modelRouting.rolePolicies)) {
        $policyAgentId = [string]$policy.agentId
        if (-not $agentIds.ContainsKey($policyAgentId) -or $rolePolicyIds.ContainsKey($policyAgentId)) { throw "Invalid or duplicate model-routing role policy '$policyAgentId'." }
        $rolePolicyIds[$policyAgentId] = $true
        foreach ($tierId in @([string]$policy.minimumTier, [string]$policy.defaultTier, [string]$policy.maximumTier)) {
            if (-not $modelTierById.ContainsKey($tierId)) { throw "Model-routing policy '$policyAgentId' references unknown tier '$tierId'." }
        }
        $minimumRank = [int]$modelTierById[[string]$policy.minimumTier].rank
        $defaultRank = [int]$modelTierById[[string]$policy.defaultTier].rank
        $maximumRank = [int]$modelTierById[[string]$policy.maximumTier].rank
        if ($minimumRank -gt $defaultRank -or $defaultRank -gt $maximumRank) { throw "Model-routing policy tiers are out of order for '$policyAgentId'." }
        $configuredAgent = @($Config.agents | Where-Object { [string]$_.id -eq $policyAgentId }) | Select-Object -First 1
        $defaultTier = $modelTierById[[string]$policy.defaultTier]
        if ([string]$configuredAgent.model -ne [string]$defaultTier.model -or [string]$configuredAgent.reasoningEffort -ne [string]$defaultTier.reasoningEffort) { throw "Agent '$policyAgentId' defaults must match its model-routing default tier." }
    }
    if ($rolePolicyIds.Count -ne $agentIds.Count) { throw 'Every configured agent must have exactly one model-routing role policy.' }
    if (-not $agentIds.ContainsKey([string]$Config.workflow.orchestration.fallbackAgentId)) { throw 'The orchestration fallback agent is not configured.' }
    foreach ($dispatchAgentId in @($Config.workflow.orchestration.dispatchPriority)) {
        if ($dispatchAgentId -eq 'orchestrator' -or -not $agentIds.ContainsKey([string]$dispatchAgentId)) { throw "Invalid orchestration dispatch agent '$dispatchAgentId'." }
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
    $responsibilities = @($Agent.responsibilities | ForEach-Object { "- $([string]$_)" }) -join "`n"
    $promptSections.Add("Configured responsibilities:`n$responsibilities`n`nConfigured handoffs: $handoffs`nRequired artifacts: $artifacts")

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

function Write-Utf8NoBomAtomic {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporaryPath = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = $temporaryPath + '.bak'
    try {
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true) }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally {
        foreach ($transientPath in @($temporaryPath, $backupPath)) {
            if (Test-Path -LiteralPath $transientPath -PathType Leaf) { Remove-Item -LiteralPath $transientPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-EcosystemFileLock {
    param(
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][scriptblock] $Action,
        [int] $TimeoutSeconds = 30
    )
    $parent = Split-Path -Parent $LockPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stream = $null
    while (-not $stream -and [DateTime]::UtcNow -lt $deadline) {
        try { $stream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 75 }
    }
    if (-not $stream) { throw "Timed out waiting for exclusive lock '$LockPath'." }
    try { return & $Action }
    finally { $stream.Dispose() }
}
function Get-TaskWorkspaceLayout {
    param(
        [Parameter(Mandatory)][string] $WorkspaceRoot,
        [Parameter(Mandatory)][string] $TaskId,
        [Parameter(Mandatory)][string] $RepositoryId,
        [Parameter(Mandatory)][string] $RunId
    )
    if ($RunId.Length -lt 12) { throw 'Workspace run ID must contain at least 12 characters.' }
    function Get-StableSegment {
        param([Parameter(Mandatory)][string] $Value)
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { $hash = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
        finally { $algorithm.Dispose() }
        return (([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant().Substring(0, 16))
    }
    $taskKey = Get-StableSegment -Value $TaskId
    $repositoryKey = Get-StableSegment -Value $RepositoryId
    [pscustomobject][ordered]@{
        ClonePath = [IO.Path]::GetFullPath((Join-Path (Join-Path $WorkspaceRoot "task-$taskKey") "repo-$repositoryKey"))
        Branch = "agent/$taskKey/$repositoryKey/$($RunId.Substring(0, 12))"
        TaskKey = $taskKey
        RepositoryKey = $repositoryKey
    }
}
Export-ModuleMember -Function Get-EcosystemRoot, Get-DefaultCodexHome, Resolve-CodexCliPath, Expand-EcosystemValue, Get-EcosystemConfig, Get-EcosystemStateRoot, Resolve-EcosystemPath, Assert-EcosystemConfig, ConvertTo-TomlString, New-AgentToml, Write-Utf8NoBom, Write-Utf8NoBomAtomic, Invoke-EcosystemFileLock, Get-TaskWorkspaceLayout