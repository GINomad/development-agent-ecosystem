[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$reconciled = [Collections.Generic.List[string]]::new()
$preserved = [Collections.Generic.List[string]]::new()
$stableTaskStatuses = @('waiting_for_input','held','review_pending','completed','interrupted')
if ([string]$task.status -notin $stableTaskStatuses -or -not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
    return [pscustomobject]@{ TaskId=$TaskId; Reconciled=@(); Preserved=@('orchestrator','health_check'); Reason='Task is active, failed, or has no durable event ledger.' }
}

$events = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
$downstreamAgentIds = @('requirements_analyst','developer','reviewer','review_verifier','pipeline_monitor','knowledge_keeper')
$downstreamResults = @($events | Where-Object { [string]$_.type -eq 'agent-result' -and [string]$_.actor -in $downstreamAgentIds } | Sort-Object { [DateTime]$_.timestampUtc })

function Get-LatestEvent {
    param([object[]] $Source)
    @($Source | Sort-Object { [DateTime]$_.timestampUtc } -Descending) | Select-Object -First 1
}

function Test-SupersededFailure {
    param(
        [Parameter(Mandatory)][DateTime] $FailureAt,
        [switch] $RequirePriorOrchestratorOutcome
    )
    if ($RequirePriorOrchestratorOutcome) {
        $priorOutcome = Get-LatestEvent -Source @($events | Where-Object { [string]$_.type -eq 'agent-result' -and [string]$_.actor -eq 'orchestrator' -and [DateTime]$_.timestampUtc -lt $FailureAt })
        if (-not $priorOutcome) { return $false }
    }
    $laterSuccess = Get-LatestEvent -Source @($downstreamResults | Where-Object { [DateTime]$_.timestampUtc -gt $FailureAt })
    if (-not $laterSuccess) { return $false }
    $failureAfterSuccess = Get-LatestEvent -Source @($events | Where-Object { [string]$_.type -eq 'agent-failure' -and [DateTime]$_.timestampUtc -gt [DateTime]$laterSuccess.timestampUtc })
    -not [bool]$failureAfterSuccess
}

$statusScript = Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1'
$orchestratorState = if ($task.agentStatuses.PSObject.Properties['orchestrator']) { $task.agentStatuses.orchestrator } else { $null }
if ($orchestratorState -and [string]$orchestratorState.status -eq 'failed') {
    $orchestratorFailure = Get-LatestEvent -Source @($events | Where-Object { [string]$_.type -eq 'agent-failure' -and [string]$_.actor -eq 'orchestrator' })
    $orchestratorFailureAt = if ($orchestratorFailure) { [DateTime]$orchestratorFailure.timestampUtc } else { [DateTime]$orchestratorState.updatedAtUtc }
    if (Test-SupersededFailure -FailureAt $orchestratorFailureAt -RequirePriorOrchestratorOutcome) {
        & $statusScript -TaskId $TaskId -AgentId orchestrator -AgentStatus completed -Message 'The earlier runner failure was superseded by successful routed-agent outcomes; the original failure evidence remains in task history.' -Actor ecosystem -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $reconciled.Add('orchestrator')
    }
    else { $preserved.Add('orchestrator') }
}

$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$healthState = if ($task.agentStatuses.PSObject.Properties['health_check']) { $task.agentStatuses.health_check } else { $null }
if ($healthState -and [string]$healthState.status -eq 'waiting') {
    $healthWaitingAt = [DateTime]$healthState.updatedAtUtc
    if (Test-SupersededFailure -FailureAt $healthWaitingAt) {
        & $statusScript -TaskId $TaskId -AgentId health_check -AgentStatus completed -Message 'A later successful targeted workflow confirmed recovery; the prior waiting diagnostic remains preserved in task history.' -Actor ecosystem -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $reconciled.Add('health_check')
    }
    else { $preserved.Add('health_check') }
}

[pscustomobject]@{
    TaskId = $TaskId
    Reconciled = @($reconciled)
    Preserved = @($preserved)
    Reason = if ($reconciled.Count) { 'Superseded control-plane states were reconciled from durable outcome chronology.' } else { 'No safely superseded control-plane state was found.' }
}
