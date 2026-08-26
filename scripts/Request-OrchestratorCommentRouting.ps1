[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]] $EventIds,
    [Parameter(Mandatory)][ValidateLength(1,1000)][string] $Reason,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.workflow.orchestration
if (-not [bool]$policy.forwardOutOfScopeComments) { throw 'Out-of-scope comment forwarding is disabled.' }
$orchestratorId = [string]$policy.agentId
if ($AgentId -eq $orchestratorId) { throw 'Orchestrator cannot forward a comment to itself.' }
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }

$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
} else { @() }
$batch = & (Join-Path $PSScriptRoot 'Get-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome
$pendingById = @{}
foreach ($comment in @($batch.comments)) { $pendingById[[string]$comment.eventId] = $comment }
$requestedIds = @($EventIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$handoffs = [Collections.Generic.List[object]]::new()
$acknowledgeIds = [Collections.Generic.List[string]]::new()

foreach ($eventId in $requestedIds) {
    $marker = "authority-handoff:$AgentId"
    $existing = @($events | Where-Object {
        [string]$_.type -eq 'agent-routing-request' -and [string]$_.actor -eq $AgentId -and
        @($_.evidence) -contains $eventId -and @($_.evidence) -contains $marker
    }) | Select-Object -First 1
    if ($existing) { $handoffs.Add($existing); continue }
    if (-not $pendingById.ContainsKey($eventId)) { throw "Comment '$eventId' is not pending for '$AgentId' and has no existing authority handoff." }
    $source = $pendingById[$eventId]
    $summary = "[Authority handoff from $AgentId] $([string]$source.text) Reason: $($Reason.Trim())"
    $handoff = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type agent-routing-request -Summary $summary -Artifact $taskPath -Evidence @($eventId, $marker, "source-event:$([string]$source.sourceEventId)") -TargetAgentId $orchestratorId -ConfigPath $ConfigPath -CodexHome $CodexHome
    $handoffs.Add($handoff)
    $acknowledgeIds.Add($eventId)
}

if ($acknowledgeIds.Count) {
    & (Join-Path $PSScriptRoot 'Acknowledge-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId $AgentId -EventIds @($acknowledgeIds) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId $AgentId -Level success -Stage authority_handoff -Summary "Forwarded $($acknowledgeIds.Count) out-of-scope comment(s) to Orchestrator." -Details $Reason.Trim() -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId $orchestratorId -Level info -Stage routing_requested -Summary "Received $($acknowledgeIds.Count) authority handoff(s) from '$AgentId'." -Details 'The trusted host will prioritize Orchestrator at the next successful handoff checkpoint.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

[pscustomobject]@{
    TaskId = $TaskId
    SourceAgentId = $AgentId
    OrchestratorAgentId = $orchestratorId
    ForwardedCount = $acknowledgeIds.Count
    HandoffEventIds = @($handoffs | ForEach-Object { [string]$_.eventId })
    Status = if ($acknowledgeIds.Count) { 'forwarded' } else { 'already-forwarded' }
}
