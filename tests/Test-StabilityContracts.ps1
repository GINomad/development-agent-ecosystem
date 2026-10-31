[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\\stability-contracts'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\\AgentEcosystem.psm1') -Force

$root = Get-EcosystemRoot
$runRoot = Join-Path $OutputRoot ('run-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $runRoot 'state'
$testConfigPath = Join-Path $runRoot 'agents.json'
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.runtime.stateRoot = $stateRoot
    $config | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $testConfigPath -Encoding utf8NoBOM

    & (Join-Path $root 'scripts\\Start-AgentContinuationRecoveryHost.ps1') -RunOnce -ConfigPath $testConfigPath -CodexHome $CodexHome | Out-Null
    $continuationHealthPath = Join-Path $stateRoot 'health\\continuation-recovery-result.json'
    $continuationHealth = Get-Content -LiteralPath $continuationHealthPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$continuationHealth.status -ne 'healthy' -or [string]$continuationHealth.continuationRepairStatus -ne 'completed' -or [string]$continuationHealth.workspaceCleanupStatus -ne 'completed') { throw 'Continuation recovery host did not persist a healthy clean-cycle result.' }

    $staleTaskRoot = Join-Path $stateRoot 'tasks\\stability-stale'
    New-Item -ItemType Directory -Path $staleTaskRoot -Force | Out-Null
    [ordered]@{ taskId='stability-stale'; status='interrupted'; agentStatuses=[ordered]@{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staleTaskRoot 'task.json') -Encoding utf8NoBOM
    [ordered]@{ taskId='stability-stale'; disposition='stale-superseded'; summary='OAuth session expired'; failureSignature='a' * 64 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staleTaskRoot 'agent-failure-stale.json') -Encoding utf8NoBOM
    $scan = & (Join-Path $root 'scripts\\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath -CodexHome $CodexHome
    if ([string]$scan.status -ne 'no-incidents' -or -not (Test-Path -LiteralPath ([string]$scan.heartbeatPath) -PathType Leaf)) { throw 'Daily incident scan did not skip stale failures and record a no-incidents heartbeat.' }

    $externalTaskRoot = Join-Path $stateRoot 'tasks\\stability-external'
    New-Item -ItemType Directory -Path $externalTaskRoot -Force | Out-Null
    [ordered]@{ taskId='stability-external'; status='interrupted'; agentStatuses=[ordered]@{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $externalTaskRoot 'task.json') -Encoding utf8NoBOM
    $externalFailurePath = Join-Path $externalTaskRoot 'agent-failure-external.json'
    [ordered]@{ taskId='stability-external'; agentId='review_verifier'; summary='Failed to authenticate: OAuth session expired'; failureSignature=('c' * 64) } | ConvertTo-Json | Set-Content -LiteralPath $externalFailurePath -Encoding utf8NoBOM
    [ordered]@{ taskId='stability-external'; agentId='review_verifier'; disposition='stale-superseded'; summary='Synthetic newer stale envelope'; failureSignature=('d' * 64) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $externalTaskRoot 'agent-failure-newer-stale.json') -Encoding utf8NoBOM
    $externalRecovery = & (Join-Path $root 'scripts\\Start-AgentHealthRecovery.ps1') -TaskId stability-external -FailurePath $externalFailurePath -SuppressExternalDelivery -SuppressTargetedResume -ConfigPath $testConfigPath -CodexHome $CodexHome
    if ([string]$externalRecovery.Status -ne 'external-dependency' -or [string]$externalRecovery.ExternalCategory -ne 'provider-authentication' -or $externalRecovery.ResultPath -or $externalRecovery.RecoveryCommit) { throw 'Expected external OAuth state started source recovery or returned a false repair envelope.' }
    # A disabled HealthCheck would fail if the daily scanner invoked it. The
    # expected OAuth dependency must be classified and skipped first.
    $config.health.enabled = $false
    $config | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $testConfigPath -Encoding utf8NoBOM
    $externalScan = & (Join-Path $root 'scripts\\Invoke-DailyHealthIncidentScan.ps1') -Repair -ConfigPath $testConfigPath -CodexHome $CodexHome
    $externalRepair = @($externalScan.repairs | Where-Object { [string]$_.taskId -eq 'stability-external' -and [string]$_.kind -eq 'source-recovery' }) | Select-Object -First 1
    if (-not $externalRepair -or [string]$externalRepair.status -ne 'external-dependency' -or [string]$externalRepair.reason -ne 'provider-authentication') { throw 'Daily scan invoked health or source recovery for expected OAuth availability.' }
    $config.health.enabled = $true
    $config | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $testConfigPath -Encoding utf8NoBOM

    $completedTaskRoot = Join-Path $stateRoot 'tasks\\stability-completed'
    New-Item -ItemType Directory -Path $completedTaskRoot -Force | Out-Null
    [ordered]@{ taskId='stability-completed'; status='completed'; currentStage='completed'; agentStatuses=[ordered]@{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $completedTaskRoot 'task.json') -Encoding utf8NoBOM
    [ordered]@{ taskId='stability-completed'; disposition='active'; summary='Synthetic ecosystem failure'; failureSignature='b' * 64 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $completedTaskRoot 'agent-failure-active.json') -Encoding utf8NoBOM
    $completedScan = & (Join-Path $root 'scripts\\Invoke-DailyHealthIncidentScan.ps1') -Repair -ConfigPath $testConfigPath -CodexHome $CodexHome
    $completedRepair = @($completedScan.repairs | Where-Object { [string]$_.taskId -eq 'stability-completed' }) | Select-Object -First 1
    if (-not $completedRepair -or [string]$completedRepair.status -ne 'not-applicable' -or [string]$completedRepair.reason -ne 'completed-task') { throw 'Daily repair attempted to mutate a completed task.' }
    $completedAfter = Get-Content -LiteralPath (Join-Path $completedTaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$completedAfter.status -ne 'completed' -or [string]$completedAfter.currentStage -ne 'completed') { throw 'Daily repair changed a completed task state.' }

    $healthRoot = Join-Path $stateRoot 'health'
    [ordered]@{ schemaVersion='1.0.0'; kind='scheduled-review'; mode='daily'; checkedAtUtc=[DateTime]::UtcNow.ToString('o'); status='failed'; error=[ordered]@{ classification='runner'; summary='Synthetic scheduled review failure.' } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $healthRoot 'scheduled-review-daily.json') -Encoding utf8NoBOM
    $scheduledScan = & (Join-Path $root 'scripts\\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath -CodexHome $CodexHome
    if ([string]$scheduledScan.status -ne 'incidents-found' -or @($scheduledScan.repairs).Count -ne 0) { throw 'Scheduled health failure was not represented as an incident without attempting recovery.' }

    $metricTaskId = 'stability-metric'
    $metricTaskRoot = Join-Path $stateRoot "tasks\\$metricTaskId"
    New-Item -ItemType Directory -Path $metricTaskRoot -Force | Out-Null
    [ordered]@{ taskId=$metricTaskId; status='interrupted'; agentStatuses=[ordered]@{} } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $metricTaskRoot 'task.json') -Encoding utf8NoBOM
    $metric = & (Join-Path $root 'scripts\\Record-AgentKnowledgeUse.ps1') -TaskId $metricTaskId -AgentId requirements_analyst -SourceKind project-skill -AccessMode used -SourceId 'skill/stability-contracts' -ConfigPath $testConfigPath -CodexHome $CodexHome
    if ([string]$metric.sourceKind -ne 'skill' -or [string]$metric.sourceKindAlias -ne 'project-skill') { throw 'Project skill telemetry alias did not normalize to the canonical source kind.' }
    $persistedMetric = Get-Content -LiteralPath (Join-Path $metricTaskRoot 'knowledge-usage.jsonl') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$persistedMetric.sourceKind -ne 'skill' -or [string]$persistedMetric.sourceKindAlias -ne 'project-skill') { throw 'Persisted telemetry lost the canonical source kind or compatibility alias.' }

    $canonical = & (Join-Path $root 'scripts/Record-AgentKnowledgeUse.ps1') -TaskId $metricTaskId -AgentId requirements_analyst -SourceKind skill -AccessMode used -SourceId 'canonical-skill' -ConfigPath $testConfigPath -CodexHome $CodexHome
    if ([string]$canonical.sourceKind -ne 'skill' -or $canonical.sourceKindAlias) { throw 'Canonical telemetry regressed while supporting project aliases.' }

    $verificationOutput = Join-Path $runRoot 'review-verification'
    & (Join-Path $root 'tests\\Test-ReviewVerification.ps1') -ConfigPath $testConfigPath -OutputRoot $verificationOutput | Out-Null
    if (-not (Test-Path -LiteralPath $verificationOutput -PathType Container)) { throw 'Review verification regression did not create its isolated output.' }

    [pscustomobject]@{
        Passed = $true
        Checks = @(
            'stale-superseded failures do not create daily incidents',
            'no-incidents scan writes a scheduler heartbeat',
            'expected OAuth authentication bypasses source recovery with a truthful envelope',
            'daily scan selects active failures and classifies expected OAuth before health validation',
            'continuation recovery writes a clean-cycle health result',
            'completed tasks are not mutated by daily recovery',
            'degraded scheduled health is represented without a task recovery',
            'project-skill normalizes to skill and retains an alias',
            'pending-downstream review verification accepts matching obligations and preserves negative cases'
        )
        OutputRoot = $runRoot
    }
}
catch { throw }
