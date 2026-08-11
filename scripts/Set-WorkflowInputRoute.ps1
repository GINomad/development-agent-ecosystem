[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{32}$')][string] $SourceEventId,
    [string[]] $TargetAgentIds = @(),
    [Parameter(Mandatory)][ValidateLength(1,2000)][string] $Rationale,
    [ValidateSet('high','medium','low')][string] $Confidence = 'medium',
    [ValidateSet('task-intake','workflow-comment')][string] $InputKind = 'workflow-comment',
    [switch] $RequiresUserInput,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.workflow.orchestration
if (-not [bool]$policy.enabled) { throw 'Workflow orchestration is disabled.' }
$orchestratorId = [string]$policy.agentId
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { throw "Task '$TaskId' has no event ledger." }

$events = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
$source = @($events | Where-Object { [string]$_.eventId -eq $SourceEventId }) | Select-Object -First 1
if (-not $source) { throw "Source event '$SourceEventId' was not found." }
if ([string]$source.type -notin @('task-created','user-comment')) { throw "Event '$SourceEventId' is not routable task intake or a workflow comment." }
if ($InputKind -eq 'task-intake' -and [string]$source.type -ne 'task-created') { throw 'task-intake requires a task-created source event.' }
if ($InputKind -eq 'workflow-comment' -and [string]$source.type -ne 'user-comment') { throw 'workflow-comment requires a user-comment source event.' }
if ([string]$source.type -eq 'user-comment') {
    $existingTarget = if ($source.PSObject.Properties['targetAgentId']) { [string]$source.targetAgentId } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($existingTarget) -and $existingTarget -ne $orchestratorId) { throw "Comment '$SourceEventId' is explicitly targeted to '$existingTarget' and cannot be reclassified." }
}

$routingPath = Join-Path $taskRoot ([string]$policy.routingArtifact)
$existingRoutes = @()
if (Test-Path -LiteralPath $routingPath -PathType Leaf) {
    $existingRoutes = @(Get-Content -LiteralPath $routingPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}
$existing = @($existingRoutes | Where-Object { [string]$_.sourceEventId -eq $SourceEventId }) | Select-Object -First 1
if ($existing) { return [pscustomobject]@{ Status='already-routed'; TaskId=$TaskId; Routing=$existing; RoutingPath=$routingPath } }

$knownAgentIds = @($config.agents | ForEach-Object { [string]$_.id })
$targets = [Collections.Generic.List[string]]::new()
foreach ($candidate in @($TargetAgentIds)) {
    $target = ([string]$candidate).Trim()
    if (-not $target -or $targets.Contains($target)) { continue }
    if ($target -eq $orchestratorId) { throw 'Orchestrator cannot route an input back to itself.' }
    if ($target -notin $knownAgentIds) { throw "Unknown target agent '$target'." }
    $targets.Add($target)
}
if (-not $RequiresUserInput -and -not $targets.Count) { $targets.Add([string]$policy.fallbackAgentId) }
if (-not [bool]$policy.allowMultipleTargets -and $targets.Count -gt 1) { throw 'Multiple routing targets are disabled.' }
if ($RequiresUserInput -and $targets.Count) { throw 'A route that requires user input cannot dispatch agents yet.' }

$routingId = [guid]::NewGuid().ToString('N')
$routedEvents = [Collections.Generic.List[object]]::new()
foreach ($target in $targets) {
    $routed = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $orchestratorId -Type workflow-input-routed -Summary ([string]$source.summary) -Artifact $routingPath -Evidence @($SourceEventId, "routing:$routingId") -TargetAgentId $target -ConfigPath $ConfigPath -CodexHome $CodexHome
    $routedEvents.Add($routed)
}
$decision = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $orchestratorId -Type routing-decision -Summary $Rationale.Trim() -Artifact $routingPath -Evidence (@($SourceEventId, "routing:$routingId") + @($routedEvents | ForEach-Object { [string]$_.eventId })) -ConfigPath $ConfigPath -CodexHome $CodexHome
$record = [ordered]@{
    routingId = $routingId
    taskId = $TaskId
    sourceEventId = $SourceEventId.ToLowerInvariant()
    sourceType = [string]$source.type
    inputKind = $InputKind
    targets = @($targets)
    rationale = $Rationale.Trim()
    confidence = $Confidence
    requiresUserInput = [bool]$RequiresUserInput
    routedEventIds = @($routedEvents | ForEach-Object { [string]$_.eventId })
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
}
$line = ($record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($routingPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }

if ([string]$source.type -eq 'user-comment') {
    & (Join-Path $PSScriptRoot 'Acknowledge-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId $orchestratorId -EventIds @($SourceEventId) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
if ($RequiresUserInput) {
    & (Join-Path $PSScriptRoot 'Open-AgentQuestion.ps1') -TaskId $TaskId -AgentId $orchestratorId -Question $Rationale.Trim() -Stage orchestration_waiting_for_input -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
else {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$task.status -ne 'running') {
        & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage orchestration_routed -Message "Orchestrator routed input to: $(@($targets) -join ', ')." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
}
& (Join-Path $PSScriptRoot 'Write-AgentActivity.ps1') -TaskId $TaskId -AgentId $orchestratorId -Level $(if ($RequiresUserInput) { 'waiting' } else { 'success' }) -Stage routing -Summary $(if ($RequiresUserInput) { 'Routing requires user input.' } else { "Input routed to $(@($targets) -join ', ')." }) -Details $Rationale.Trim() -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{ Status=if ($RequiresUserInput) { 'waiting-for-input' } else { 'routed' }; TaskId=$TaskId; Routing=[pscustomobject]$record; DecisionEventId=[string]$decision.eventId; RoutingPath=$routingPath }
