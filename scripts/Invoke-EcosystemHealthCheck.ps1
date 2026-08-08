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

    $codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
    if (-not $codexCommand) { $codexCommand = Get-Command codex -ErrorAction SilentlyContinue }
    if ($codexCommand) {
        $codexVersion = (& $codexCommand.Source --version 2>&1 | Out-String).Trim()
        Add-HealthCheck -Id 'codex-cli' -Status passed -Summary "Codex CLI is available: $codexVersion" -Evidence @([string]$codexCommand.Source)
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
    $missingAgents = @($config.agents | Where-Object { -not (Test-Path -LiteralPath (Join-Path $agentInstallRoot "$($_.name).toml") -PathType Leaf) })
    if (-not $missingAgents.Count) {
        Add-HealthCheck -Id 'installed-agents' -Status passed -Summary "All $(@($config.agents).Count) generated agent definitions are installed." -Evidence @($agentInstallRoot)
        Add-Repair -Id 'sync-agent-definitions' -Status not-applicable -Summary 'Installed agent definitions are complete.'
    }
    elseif ($Repair -and [string]$config.health.repairMode -eq 'safe-deterministic-only') {
        & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install | Out-Null
        $stillMissing = @($config.agents | Where-Object { -not (Test-Path -LiteralPath (Join-Path $agentInstallRoot "$($_.name).toml") -PathType Leaf) })
        if ($stillMissing.Count) {
            Add-HealthCheck -Id 'installed-agents' -Status failed -Summary "Agent definition repair did not restore: $($stillMissing.name -join ', ')." -Evidence @($agentInstallRoot)
            Add-Repair -Id 'sync-agent-definitions' -Status failed -Summary 'Generated agent definitions remain incomplete.'
        }
        else {
            Add-HealthCheck -Id 'installed-agents' -Status repaired -Summary 'Missing generated agent definitions were reinstalled.' -Evidence @($agentInstallRoot)
            Add-Repair -Id 'sync-agent-definitions' -Status applied -Summary 'Recompiled and installed agent TOML from canonical JSON, prompts, and skills.'
        }
    }
    else {
        Add-HealthCheck -Id 'installed-agents' -Status failed -Summary "Missing agent definitions: $($missingAgents.name -join ', ')." -Evidence @($agentInstallRoot)
        Add-Repair -Id 'sync-agent-definitions' -Status requires-approval -Summary 'Run the trusted health check with -Repair to reinstall derived agent definitions.'
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

            $codexLogPath = Join-Path $taskRoot 'workflow-codex.jsonl'
            if ($taskStatus -eq 'failed') {
                $failureEvent = @($ledgerEvents | Where-Object { $_.type -eq 'workflow-status' } | Sort-Object timestampUtc -Descending | Select-Object -First 1)
                $failureSummary = if (-not [string]::IsNullOrWhiteSpace([string]$task.lastMessage)) { [string]$task.lastMessage } elseif ($failureEvent.Count) { [string]$failureEvent[0].summary } else { 'Workflow failed without a persisted summary.' }
                $lastDiagnostic = if (Test-Path -LiteralPath $codexLogPath) { (Get-Content -LiteralPath $codexLogPath -Tail 1 -Encoding UTF8 | Out-String).Trim() } else { $failureSummary }
                $failureEvidence = @($taskPath, $ledgerPath)
                if (Test-Path -LiteralPath $codexLogPath) { $failureEvidence += $codexLogPath }
                Add-HealthCheck -Id 'agent-failure' -Status failed -Summary "Workflow is failed: $failureSummary" -Evidence $failureEvidence
                if ($lastDiagnostic) { $failureParts.Add("diagnostic:$lastDiagnostic") }
                Add-Repair -Id 'source-correction' -Status requires-approval -Summary 'Health Check Agent must diagnose the log; Developer owns any source-code correction.'
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
        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor health_check -Type agent-result -Summary ([string]$result.summary) -Artifact $taskResultPath -Evidence @($resultPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $healthAgentStatus = if ($overallStatus -eq 'unhealthy') { 'waiting' } else { 'completed' }
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus $healthAgentStatus -Stage health_check -Message ([string]$result.summary) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    [pscustomobject]@{ ResultPath=$resultPath; Result=[pscustomobject]$result }
}
catch {
    if ($TaskId -and (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId health_check -AgentStatus failed -Stage health_check -Message $_.Exception.Message -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
    throw
}
