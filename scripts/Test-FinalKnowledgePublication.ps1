[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function New-FinalPublicationDecision {
    param([bool] $Eligible, [string] $Reason, [object] $OutcomeEvent = $null, [string] $SummarySha256 = '')
    [pscustomobject][ordered]@{ TaskId=$TaskId; Eligible=$Eligible; Reason=$Reason; OutcomeEventId=if ($OutcomeEvent) { [string]$OutcomeEvent.eventId } else { $null }; SummarySha256=$SummarySha256 }
}

function ConvertTo-UtcTimestamp {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) { return $null }
    $parsed.UtcDateTime
}

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$summaryPath = Join-Path $taskRoot 'task-summary.json'
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$task.status -in @('failed','waiting_for_input','held','review_pending')) { return New-FinalPublicationDecision $false 'task-status-blocked' }
if ($task.PSObject.Properties['currentStage'] -and [string]$task.currentStage -in @('awaiting_pull_request','pipeline_non_success')) { return New-FinalPublicationDecision $false "task-stage-preserved:$([string]$task.currentStage)" }
if (-not $task.PSObject.Properties['agentStatuses'] -or -not $task.agentStatuses.PSObject.Properties['knowledge_keeper'] -or [string]$task.agentStatuses.knowledge_keeper.status -ne 'completed') { return New-FinalPublicationDecision $false 'knowledge-keeper-not-completed' }
foreach ($agentId in @('requirements_analyst','developer','reviewer','review_verifier','pipeline_monitor')) {
    if (-not $task.agentStatuses.PSObject.Properties[$agentId] -or [string]$task.agentStatuses.$agentId.status -notin @('completed','skipped')) { return New-FinalPublicationDecision $false "delivery-agent-not-terminal:$agentId" }
}
if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return New-FinalPublicationDecision $false 'task-summary-missing' }
try { $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return New-FinalPublicationDecision $false 'task-summary-invalid' }
if ([string]$summary.taskId -ne $TaskId -or [string]$summary.status -ne 'completed') { return New-FinalPublicationDecision $false 'task-summary-not-completed' }
$summarySha256 = Get-EcosystemFileSha256 -Path $summaryPath
$events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) { @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } }) } else { @() }
$summaryFullPath = [IO.Path]::GetFullPath($summaryPath)
$candidates = @($events | Where-Object { [string]$_.type -eq 'agent-result' -and [string]$_.actor -eq 'knowledge_keeper' -and $_.artifact -and [IO.Path]::GetFullPath([string]$_.artifact) -eq $summaryFullPath -and @($_.evidence) -contains 'agent:knowledge_keeper' } | Sort-Object { ConvertTo-UtcTimestamp $_.timestampUtc } -Descending)
if (-not $candidates.Count) { return New-FinalPublicationDecision $false 'knowledge-publication-missing' $null $summarySha256 }
$outcome = $candidates[0]
$outcomeAtUtc = ConvertTo-UtcTimestamp $outcome.timestampUtc
if (-not $outcomeAtUtc) { return New-FinalPublicationDecision $false 'knowledge-publication-time-invalid' $outcome $summarySha256 }
$hashEvidence = "task-summary-sha256:$summarySha256"
if (@($outcome.evidence) -notcontains $hashEvidence) { return New-FinalPublicationDecision $false 'task-summary-not-bound-to-publication' $outcome $summarySha256 }
foreach ($binding in @(@{ Property='workflowAttemptId'; AgentProperty='workflowAttemptAgentId'; Prefix='execution-attempt:' }, @{ Property='executionRunId'; AgentProperty=$null; Prefix='execution-run:' }, @{ Property='workspaceLeaseId'; AgentProperty=$null; Prefix='workspace-lease:' })) {
    if (-not $task.PSObject.Properties[$binding.Property] -or [string]::IsNullOrWhiteSpace([string]$task.$($binding.Property))) { return New-FinalPublicationDecision $false "knowledge-publication-binding-missing:$($binding.Property)" $outcome $summarySha256 }
    if ($binding.AgentProperty -and (-not $task.PSObject.Properties[$binding.AgentProperty] -or [string]$task.$($binding.AgentProperty) -ne 'knowledge_keeper')) { return New-FinalPublicationDecision $false "knowledge-publication-binding-mismatch:$($binding.Property)" $outcome $summarySha256 }
    if (@($outcome.evidence) -notcontains ($binding.Prefix + [string]$task.$($binding.Property))) { return New-FinalPublicationDecision $false "knowledge-publication-binding-mismatch:$($binding.Property)" $outcome $summarySha256 }
}
$reopenedAtUtc = if ($task.PSObject.Properties['reopenedAtUtc']) { ConvertTo-UtcTimestamp $task.reopenedAtUtc } else { $null }
if ($reopenedAtUtc -and $reopenedAtUtc -gt $outcomeAtUtc) { return New-FinalPublicationDecision $false 'task-reopened-after-publication' $outcome $summarySha256 }
$acknowledged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($ack in @($events | Where-Object { [string]$_.type -eq 'user-comment-acknowledged' })) { foreach ($value in @($ack.evidence)) { if ($value) { $null = $acknowledged.Add([string]$value) } } }
$newUserInput = @($events | Where-Object { [string]$_.type -eq 'user-comment' -and -not $acknowledged.Contains([string]$_.eventId) -and (ConvertTo-UtcTimestamp $_.timestampUtc) -gt $outcomeAtUtc })
if ($newUserInput.Count) { return New-FinalPublicationDecision $false 'new-user-input-after-publication' $outcome $summarySha256 }
New-FinalPublicationDecision $true 'validated-final-knowledge-publication' $outcome $summarySha256
