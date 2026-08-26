[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [switch] $Repair,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.health.enabled) { throw 'Health checks are disabled in config/agents.json.' }

$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$healthRoot = Join-Path $stateRoot 'health'
New-Item -ItemType Directory -Path $healthRoot -Force | Out-Null
$checks = [Collections.Generic.List[object]]::new()
$repairs = [Collections.Generic.List[object]]::new()
$failureParts = [Collections.Generic.List[string]]::new()
$taskRoot = if ($TaskId) { Join-Path $stateRoot "tasks\$TaskId" } else { $null }
$taskPath = if ($taskRoot) { Join-Path $taskRoot 'task.json' } else { $null }
$policyCompatibilityPrepared = $false

function Add-HealthCheck {
    param([string] $Id, [ValidateSet('passed','warning','failed','repaired')][string] $Status, [string] $Summary, [string[]] $Evidence = @())
    $checks.Add([pscustomobject][ordered]@{ id=$Id; status=$Status; summary=$Summary; evidence=@($Evidence) })
    if ($Status -eq 'failed') { $failureParts.Add("${Id}:$Summary") }
}

function Add-Repair {
    param([string] $Id, [ValidateSet('applied','not-applicable','requires-approval','failed')][string] $Status, [string] $Summary)
    $repairs.Add([pscustomobject][ordered]@{ id=$Id; status=$Status; summary=$Summary })
}

if ($TaskId -and (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus running -Stage health_check -Message 'Health Check Agent is diagnosing the workflow failure.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

try {
    Add-HealthCheck -Id 'configuration' -Status passed -Summary 'Canonical ecosystem configuration loaded and passed semantic validation.' -Evidence @($ConfigPath)

    $codexCliPath = Resolve-CodexCliPath
    if ($codexCliPath) {
        $codexVersion = (& $codexCliPath --version 2>&1 | Out-String).Trim()
        Add-HealthCheck -Id 'codex-cli' -Status passed -Summary "Codex CLI is available: $codexVersion" -Evidence @($codexCliPath)
    }
    else {
        Add-HealthCheck -Id 'codex-cli' -Status failed -Summary 'Codex CLI was not found in the workflow environment.'
    }

    try {
        $validation = & (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
        Add-HealthCheck -Id 'ecosystem-validation' -Status passed -Summary "Complete ecosystem validation passed with $(@($validation.Checks).Count) checks."
    }
    catch {
        Add-HealthCheck -Id 'ecosystem-validation' -Status failed -Summary $_.Exception.Message
    }

    $agentInstallRoot = Resolve-EcosystemPath -Value ([string]$config.runtime.agentInstallRoot) -Config $config -CodexHome $CodexHome
    $resolvedCodexHome = Get-DefaultCodexHome -Override $CodexHome
    $compatibilitySuffix = [string]$config.runtime.elevatedFallback.agentProfileSuffix
    $expectCompatibilityProfiles = @($config.agents | Where-Object { Test-Path -LiteralPath (Join-Path $agentInstallRoot "$($_.name)$compatibilitySuffix.toml") -PathType Leaf }).Count -gt 0

    function Get-AgentDefinitionDrift {
        $drift = [Collections.Generic.List[object]]::new()
        foreach ($agent in @($config.agents)) {
            $definitions = [Collections.Generic.List[object]]::new()
            $definitions.Add([pscustomobject]@{ Agent=$agent; Name=[string]$agent.name })
            if ($expectCompatibilityProfiles) {
                $compatibleAgent = [pscustomobject][ordered]@{
                    id = [string]$agent.id
                    name = ([string]$agent.name + $compatibilitySuffix)
                    description = ([string]$agent.description + ' Host-compatible profile for an explicitly confirmed OS-policy fallback.')
                    responsibilities = @($agent.responsibilities)
                    model = if ($agent.PSObject.Properties['model']) { [string]$agent.model } else { $null }
                    reasoningEffort = [string]$agent.reasoningEffort
                    sandboxMode = [string]$config.runtime.elevatedFallback.sandboxMode
                    promptPaths = @($agent.promptPaths) + @([string]$config.runtime.elevatedFallback.compatibilityPromptPath)
                    skillPaths = @($agent.skillPaths)
                    handoffs = @($agent.handoffs)
                    requiredArtifacts = @($agent.requiredArtifacts)
                }
                $definitions.Add([pscustomobject]@{ Agent=$compatibleAgent; Name=[string]$compatibleAgent.name })
            }
            foreach ($definition in $definitions) {
                $path = Join-Path $agentInstallRoot "$([string]$definition.Name).toml"
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $drift.Add([pscustomobject]@{ name=[string]$definition.Name; path=$path; reason='missing' })
                    continue
                }
                $expected = New-AgentToml -Agent $definition.Agent -Config $config -CodexHome $resolvedCodexHome
                $actual = [IO.File]::ReadAllText($path)
                if (-not [string]::Equals($actual, $expected, [StringComparison]::Ordinal)) {
                    $drift.Add([pscustomobject]@{ name=[string]$definition.Name; path=$path; reason='outdated' })
                }
            }
        }
        return @($drift)
    }

    $agentDefinitionDrift = @(Get-AgentDefinitionDrift)
    if (-not $agentDefinitionDrift.Count) {
        Add-HealthCheck -Id 'installed-agents' -Status passed -Summary "All installed generated agent definitions match canonical configuration, prompts, and skills." -Evidence @($agentInstallRoot)
        Add-Repair -Id 'sync-agent-definitions' -Status not-applicable -Summary 'Installed agent definitions are current.'
    }
    elseif ($Repair -and [string]$config.health.repairMode -eq 'safe-deterministic-only') {
        & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install -IncludeHostCompatibilityProfile:$expectCompatibilityProfiles | Out-Null
        $remainingAgentDefinitionDrift = @(Get-AgentDefinitionDrift)
        if ($remainingAgentDefinitionDrift.Count) {
            Add-HealthCheck -Id 'installed-agents' -Status failed -Summary "Agent definition repair left stale files: $($remainingAgentDefinitionDrift.name -join ', ')." -Evidence @($remainingAgentDefinitionDrift.path)
            Add-Repair -Id 'sync-agent-definitions' -Status failed -Summary 'Generated agent definitions remain missing or outdated.'
        }
        else {
            Add-HealthCheck -Id 'installed-agents' -Status repaired -Summary "Recompiled and installed $(@($config.agents).Count) current agent definitions$(if ($expectCompatibilityProfiles) { ' and their host-compatible profiles' } else { '' })." -Evidence @($agentInstallRoot)
            Add-Repair -Id 'sync-agent-definitions' -Status applied -Summary 'Recompiled and installed agent TOML from canonical JSON, prompts, and skills after content drift detection.'
        }
    }
    else {
        Add-HealthCheck -Id 'installed-agents' -Status failed -Summary "Missing or outdated agent definitions: $($agentDefinitionDrift.name -join ', ')." -Evidence @($agentDefinitionDrift.path)
        Add-Repair -Id 'sync-agent-definitions' -Status requires-approval -Summary 'Run the trusted health check with -Repair to reinstall current derived agent definitions.'
    }

    $reviewConfigPath = Join-Path (Resolve-EcosystemPath -Value ([string]$config.review.monitorDataRoot) -Config $config -CodexHome $CodexHome) 'config.json'
    if (Test-Path -LiteralPath $reviewConfigPath -PathType Leaf) {
        Add-HealthCheck -Id 'review-monitor-config' -Status passed -Summary 'Derived Review Monitor configuration exists.' -Evidence @($reviewConfigPath)
        Add-Repair -Id 'sync-review-config' -Status not-applicable -Summary 'Derived Review Monitor configuration is present.'
    }
    elseif ($Repair -and [string]$config.health.repairMode -eq 'safe-deterministic-only') {
        & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        Add-HealthCheck -Id 'review-monitor-config' -Status repaired -Summary 'Derived Review Monitor configuration was regenerated.' -Evidence @($reviewConfigPath)
        Add-Repair -Id 'sync-review-config' -Status applied -Summary 'Regenerated Review Monitor configuration from canonical JSON.'
    }
    else {
        Add-HealthCheck -Id 'review-monitor-config' -Status failed -Summary 'Derived Review Monitor configuration is missing.' -Evidence @($reviewConfigPath)
        Add-Repair -Id 'sync-review-config' -Status requires-approval -Summary 'Run the trusted health check with -Repair to regenerate derived review configuration.'
    }

    try {
        $dashboardHealth = Invoke-RestMethod -Uri ([string]$config.health.dashboardHealthUrl) -TimeoutSec 3
        if ([string]$dashboardHealth.status -eq 'ok') { Add-HealthCheck -Id 'dashboard' -Status passed -Summary 'Agent Desk health endpoint returned ok.' -Evidence @([string]$config.health.dashboardHealthUrl) }
        else { Add-HealthCheck -Id 'dashboard' -Status warning -Summary 'Agent Desk responded without an ok status.' -Evidence @([string]$config.health.dashboardHealthUrl) }
    }
    catch {
        Add-HealthCheck -Id 'dashboard' -Status warning -Summary 'Agent Desk health endpoint is not reachable.' -Evidence @([string]$config.health.dashboardHealthUrl)
    }

    if ($TaskId) {
        if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
            Add-HealthCheck -Id 'task-state' -Status failed -Summary "Task '$TaskId' was not found." -Evidence @($taskPath)
        }
        else {
            $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $taskStatus = [string]$task.status
            $processAlive = $false
            if ($task.PSObject.Properties['workflowProcessId']) { $processAlive = [bool](Get-Process -Id ([int]$task.workflowProcessId) -ErrorAction SilentlyContinue) }
            if ($taskStatus -eq 'running' -and -not $processAlive) {
                if ($Repair -and [string]$config.health.repairMode -eq 'safe-deterministic-only') {
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage health_check -Message 'Health check detected a running task without a live workflow process.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    Add-HealthCheck -Id 'task-process' -Status repaired -Summary 'Orphaned running task was marked interrupted.' -Evidence @($taskPath)
                    Add-Repair -Id 'mark-orphan-interrupted' -Status applied -Summary 'Changed only mutable runtime state from running to interrupted.'
                }
                else {
                    Add-HealthCheck -Id 'task-process' -Status failed -Summary 'Task is running but its workflow process is not alive.' -Evidence @($taskPath)
                    Add-Repair -Id 'mark-orphan-interrupted' -Status requires-approval -Summary 'Run the trusted health check with -Repair to mark the orphaned task interrupted.'
                }
            }
            else {
                Add-HealthCheck -Id 'task-process' -Status passed -Summary "Task status is $taskStatus; process consistency check passed." -Evidence @($taskPath)
                Add-Repair -Id 'mark-orphan-interrupted' -Status not-applicable -Summary 'Task process state is consistent.'
            }

            $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
            $invalidLedgerLines = 0
            $ledgerEvents = [Collections.Generic.List[object]]::new()
            if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                foreach ($line in @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    try { $ledgerEvents.Add(($line | ConvertFrom-Json)) } catch { $invalidLedgerLines++ }
                }
            }
            if ($invalidLedgerLines) { Add-HealthCheck -Id 'task-ledger' -Status failed -Summary "$invalidLedgerLines invalid JSONL event(s) found." -Evidence @($ledgerPath) }
            else { Add-HealthCheck -Id 'task-ledger' -Status passed -Summary 'Task ledger is readable append-only JSONL.' -Evidence @($ledgerPath) }

            $continuationInspection = & (Join-Path $PSScriptRoot 'Repair-AgentContinuations.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
            $actionableContinuations = @($continuationInspection.Items | Where-Object { [string]$_.Status -in @('continuation-required','restart-required') })
            $incompletePublications = @($continuationInspection.Items | Where-Object { [string]$_.Status -eq 'publication-incomplete' })
            if ($actionableContinuations.Count -and $Repair -and [string]$config.health.repairMode -eq 'safe-deterministic-only') {
                $continuationRepair = & (Join-Path $PSScriptRoot 'Repair-AgentContinuations.ps1') -TaskId $TaskId -Repair -ElevatedApproved -ConfigPath $ConfigPath -CodexHome $CodexHome
                $remainingContinuations = @($continuationRepair.Items | Where-Object { [string]$_.Status -in @('continuation-required','restart-required') })
                if ($remainingContinuations.Count) {
                    Add-HealthCheck -Id 'durable-continuation' -Status failed -Summary 'A missing agent continuation remained after deterministic reconciliation.' -Evidence @($ledgerPath)
                    Add-Repair -Id 'reconcile-agent-continuation' -Status failed -Summary 'The next role was not recovered.'
                }
                else {
                    Add-HealthCheck -Id 'durable-continuation' -Status repaired -Summary 'Recovered a successful agent outcome whose host exited before the next handoff.' -Evidence @($ledgerPath)
                    Add-Repair -Id 'reconcile-agent-continuation' -Status applied -Summary 'Started only the missing next role through the existing guarded continuation chain.'
                }
            }
            elseif ($actionableContinuations.Count) {
                Add-HealthCheck -Id 'durable-continuation' -Status failed -Summary "$($actionableContinuations.Count) successful outcome(s) require deterministic continuation reconciliation." -Evidence @($ledgerPath)
                Add-Repair -Id 'reconcile-agent-continuation' -Status requires-approval -Summary 'Run the trusted health check with -Repair or wait for the scheduled continuation reconciler.'
            }
            elseif ($incompletePublications.Count) {
                Add-HealthCheck -Id 'durable-continuation' -Status warning -Summary 'A durable continuation request exists without a complete published agent outcome.' -Evidence @($ledgerPath)
                Add-Repair -Id 'reconcile-agent-continuation' -Status not-applicable -Summary 'Continuation remains fail-closed until successful outcome publication completes.'
            }
            else {
                Add-HealthCheck -Id 'durable-continuation' -Status passed -Summary 'No orphaned successful agent continuation was detected.' -Evidence @($ledgerPath)
                Add-Repair -Id 'reconcile-agent-continuation' -Status not-applicable -Summary 'Every durable continuation is active, gated, or already reconciled.'
            }

            $codexLogPath = Join-Path $taskRoot 'workflow-codex.jsonl'
            if ($taskStatus -eq 'failed') {
                $failureEvent = @($ledgerEvents | Where-Object { $_.type -eq 'workflow-status' } | Sort-Object timestampUtc -Descending | Select-Object -First 1)
                $failureSummary = if (-not [string]::IsNullOrWhiteSpace([string]$task.lastMessage)) { [string]$task.lastMessage } elseif ($failureEvent.Count) { [string]$failureEvent[0].summary } else { 'Workflow failed without a persisted summary.' }
                $lastDiagnostic = if (Test-Path -LiteralPath $codexLogPath) { (Get-Content -LiteralPath $codexLogPath -Tail 1 -Encoding UTF8 | Out-String).Trim() } else { $failureSummary }
                $failureEvidence = @($taskPath, $ledgerPath)
                if (Test-Path -LiteralPath $codexLogPath) { $failureEvidence += $codexLogPath }
                $osPolicyBlocked = $failureSummary -match 'CreateProcessWithLogonW|Windows sandbox|error\s*1260' -or $lastDiagnostic -match 'CreateProcessWithLogonW|Windows sandbox|error\s*1260'
                if ($osPolicyBlocked -and [bool]$config.runtime.elevatedFallback.installCompatibleAgentsOnDetection) {
                    if ($Repair) {
                        $compatibilitySync = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install -IncludeHostCompatibilityProfile
                        $suffix = [string]$config.runtime.elevatedFallback.agentProfileSuffix
                        $missingCompatibleAgents = @($config.agents | Where-Object { -not (Test-Path -LiteralPath (Join-Path $agentInstallRoot "$($_.name)$suffix.toml") -PathType Leaf) })
                        if ($missingCompatibleAgents.Count) {
                            Add-HealthCheck -Id 'os-policy-compatibility' -Status failed -Summary "Host-compatible agent profiles were not installed: $($missingCompatibleAgents.name -join ', ')." -Evidence @($agentInstallRoot)
                            Add-Repair -Id 'install-host-compatible-agents' -Status failed -Summary 'The derived compatibility profile remains incomplete.'
                        }
                        else {
                            $policyCompatibilityPrepared = $true
                            Add-HealthCheck -Id 'os-policy-compatibility' -Status repaired -Summary "Installed $(@($config.agents).Count) host-compatible agent profiles for the confirmed current-user workflow path." -Evidence @($compatibilitySync.AgentFiles | Where-Object { $_ -like "*$suffix.toml" })
                            Add-Repair -Id 'install-host-compatible-agents' -Status applied -Summary 'Recompiled every agent with the OS-policy compatibility prompt and danger-full-access sandbox mode. Dashboard confirmation is still required to select them.'
                        }
                    }
                    else {
                        Add-HealthCheck -Id 'os-policy-compatibility' -Status warning -Summary 'OS policy error 1260 requires derived host-compatible agent profiles.' -Evidence $failureEvidence
                        Add-Repair -Id 'install-host-compatible-agents' -Status available -Summary 'Run Health Check with -Repair to compile the compatibility profiles; standing policy selects them by default.'
                    }
                    Add-HealthCheck -Id 'agent-failure' -Status warning -Summary "Sandboxed workflow stopped: $failureSummary" -Evidence $failureEvidence
                }
                else {
                    Add-HealthCheck -Id 'agent-failure' -Status failed -Summary "Workflow is failed: $failureSummary" -Evidence $failureEvidence
                    if ($lastDiagnostic) { $failureParts.Add("diagnostic:$lastDiagnostic") }
                    Add-Repair -Id 'source-correction' -Status requires-approval -Summary 'Health Check Agent must diagnose the log; Developer owns any source-code correction.'
                }
            }
            else {
                Add-HealthCheck -Id 'agent-failure' -Status passed -Summary 'Task is not in failed state.'
            }
        }
    }

    $failedCount = @($checks | Where-Object status -eq 'failed').Count
    $warningCount = @($checks | Where-Object status -eq 'warning').Count
    $repairCount = @($checks | Where-Object status -eq 'repaired').Count
    $overallStatus = if ($failedCount) { 'unhealthy' } elseif ($repairCount) { 'repaired' } elseif ($warningCount) { 'degraded' } else { 'healthy' }
    $failureSignature = $null
    if ($failureParts.Count) {
        $signatureText = $failureParts -join '|'
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $failureSignature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($signatureText)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    $result = [ordered]@{
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        taskId = if ($TaskId) { $TaskId } else { $null }
        status = $overallStatus
        failureSignature = $failureSignature
        checks = @($checks)
        repairs = @($repairs)
        summary = "Health check completed: status=$overallStatus, failed=$failedCount, warnings=$warningCount, repaired=$repairCount."
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $resultPath = Join-Path $healthRoot "health-check-$stamp.json"
    $json = ($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    Write-Utf8NoBom -Path $resultPath -Content $json
    if ($TaskId -and (Test-Path -LiteralPath $taskRoot -PathType Container)) {
        $taskResultPath = Join-Path $taskRoot 'health-check-result.json'
        Write-Utf8NoBom -Path $taskResultPath -Content $json
        if ($policyCompatibilityPrepared) {
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage os_policy_compatibility_ready -Message 'Health Check installed host-compatible profiles after Windows policy error 1260; standing policy selects them on the next targeted resume.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        $healthStage = if ($policyCompatibilityPrepared) { 'os_policy_compatibility_ready' } else { 'health_check' }
        if ($overallStatus -eq 'unhealthy') {
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus waiting -Stage $healthStage -Message ([string]$result.summary) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            & (Join-Path $PSScriptRoot 'Save-AgentCheckpoint.ps1') -TaskId $TaskId -AgentId health_check -Status waiting -Summary ([string]$result.summary) -NextStep 'Resolve the reported health blocker, then rerun Health Check.' -EvidenceRefs @($resultPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        else {
            & (Join-Path $PSScriptRoot 'Publish-AgentOutcome.ps1') -TaskId $TaskId -AgentId health_check -Summary ([string]$result.summary) -Evidence @($resultPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
    }
    [pscustomobject]@{ ResultPath=$resultPath; Result=[pscustomobject]$result }
}
catch {
    if ($TaskId -and (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus failed -Stage health_check -Message $_.Exception.Message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    throw
}
