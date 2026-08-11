[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [ValidateRange(20,500)][int] $Tail = 200,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function Limit-Text {
    param([AllowNull()][object] $Value, [int] $Maximum = 4000)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $text = $text -replace '(?i)(authorization:\s*bearer\s+)[^\s"'']+', '$1[redacted]'
    $text = $text -replace '(?i)((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s"'']+', '$1[redacted]'
    if ($text.Length -le $Maximum) { return $text }
    return $text.Substring(0, $Maximum) + '...'
}

function Add-ActivityEntry {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Entries,
        [string] $Id,
        [AllowNull()][string] $TimestampUtc,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Level,
        [AllowNull()][string] $Stage,
        [Parameter(Mandatory)][string] $Summary,
        [AllowNull()][string] $Details,
        [int] $Sequence
    )
    $Entries.Add([pscustomobject][ordered]@{
        id = $Id
        timestampUtc = $TimestampUtc
        source = $Source
        level = $Level
        stage = $Stage
        summary = Limit-Text -Value $Summary -Maximum 4000
        details = Limit-Text -Value $Details -Maximum 8000
        sequence = $Sequence
    })
}

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { $_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$entries = New-Object 'Collections.Generic.List[object]'
$sequence = 0

$activityPath = Join-Path $taskRoot 'agent-activity.jsonl'
if (Test-Path -LiteralPath $activityPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $activityPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.agentId -ne $AgentId) { continue }
        $sequence++
        Add-ActivityEntry -Entries $entries -Id ([string]$record.activityId) -TimestampUtc ([string]$record.timestampUtc) -Source 'activity' -Level ([string]$record.level) -Stage ([string]$record.stage) -Summary ([string]$record.summary) -Details ([string]$record.details) -Sequence $sequence
    }
}

$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        $isAgentActor = [string]$record.actor -eq $AgentId
        $isTargetedUserComment = [string]$record.type -in @('user-comment','workflow-input-routed') -and $record.PSObject.Properties['targetAgentId'] -and [string]$record.targetAgentId -eq $AgentId
        if (-not $isAgentActor -and -not $isTargetedUserComment) { continue }
        $sequence++
        $level = switch ([string]$record.type) {
            'agent-failure' { 'error' }
            'question-opened' { 'waiting' }
            'question-resolved' { 'success' }
            default { 'info' }
        }
        $entryStage = if ($isTargetedUserComment) { if ([string]$record.type -eq 'workflow-input-routed') { 'orchestrator-routed-input' } else { 'user-comment' } } else { $null }
        $entrySummary = if ($isTargetedUserComment) { if ([string]$record.type -eq 'workflow-input-routed') { "Orchestrator routed: $([string]$record.summary)" } else { "User comment: $([string]$record.summary)" } } else { [string]$record.summary }
        Add-ActivityEntry -Entries $entries -Id ([string]$record.eventId) -TimestampUtc ([string]$record.timestampUtc) -Source 'ledger' -Level $level -Stage $entryStage -Summary $entrySummary -Details $null -Sequence $sequence
    }
}

if ($AgentId -eq [string]$config.workflow.orchestration.agentId) {
    $workflowPath = Join-Path $taskRoot 'workflow-codex.jsonl'
    if (Test-Path -LiteralPath $workflowPath -PathType Leaf) {
        $workflowSequence = 0
        foreach ($line in @(Get-Content -LiteralPath $workflowPath -Encoding UTF8)) {
            if ($line -notmatch '^\s*\{') { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ([string]$record.type -notin @('item.started','item.completed') -or -not $record.PSObject.Properties['item']) { continue }
            $item = $record.item
            $itemType = [string]$item.type
            if ($itemType -notin @('agent_message','command_execution','mcp_tool_call')) { continue }
            $workflowSequence++
            $sequence++
            $level = 'progress'
            $summary = ''
            $details = $null
            if ($itemType -eq 'agent_message') {
                if ([string]$record.type -ne 'item.completed') { continue }
                $level = 'info'
                $summary = [string]$item.text
            }
            elseif ($itemType -eq 'command_execution') {
                $status = [string]$item.status
                if ($status -eq 'failed' -or ($item.PSObject.Properties['exit_code'] -and $null -ne $item.exit_code -and [int]$item.exit_code -ne 0)) { $level = 'error' }
                elseif ($status -eq 'completed') { $level = 'success' }
                $summary = "Command $status"
                if ($item.PSObject.Properties['exit_code'] -and $null -ne $item.exit_code) { $summary += " (exit $($item.exit_code))" }
                $details = [string]$item.command
            }
            else {
                $status = [string]$item.status
                if ($status -eq 'failed') { $level = 'error' } elseif ($status -eq 'completed') { $level = 'success' }
                $toolName = if ($item.PSObject.Properties['tool']) { [string]$item.tool } elseif ($item.PSObject.Properties['name']) { [string]$item.name } else { 'tool' }
                $summary = "$toolName $status"
            }
            if ([string]::IsNullOrWhiteSpace($summary)) { continue }
            Add-ActivityEntry -Entries $entries -Id ("orchestration-$workflowSequence") -TimestampUtc $null -Source 'orchestration' -Level $level -Stage 'orchestration' -Summary $summary -Details $details -Sequence $sequence
        }
    }
}

$statusValue = $null
$statusUpdatedAt = $null
$statusMessage = $null
if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$AgentId]) {
    $state = $task.agentStatuses.$AgentId
    $statusValue = [string]$state.status
    $statusUpdatedAt = [string]$state.updatedAtUtc
    $statusMessage = [string]$state.message
}
if ([string]::IsNullOrWhiteSpace($statusValue)) { $statusValue = 'pending' }
if ($entries.Count -eq 0 -or -not [string]::IsNullOrWhiteSpace($statusMessage)) {
    $sequence++
    $level = switch ($statusValue) {
        'running' { 'progress' }
        'completed' { 'success' }
        'waiting' { 'waiting' }
        'failed' { 'error' }
        'skipped' { 'warning' }
        default { 'info' }
    }
    $snapshotSummary = if ([string]::IsNullOrWhiteSpace($statusMessage)) { "$AgentId is $statusValue." } else { $statusMessage }
    Add-ActivityEntry -Entries $entries -Id 'current-status' -TimestampUtc $statusUpdatedAt -Source 'status' -Level $level -Stage ([string]$task.currentStage) -Summary $snapshotSummary -Details $null -Sequence $sequence
}

$currentStatusEntry = @($entries | Where-Object { [string]$_.id -eq 'current-status' } | Select-Object -Last 1)
$orderedEntries = @($entries | Where-Object { [string]$_.id -ne 'current-status' } | Sort-Object @{ Expression={ if ([string]::IsNullOrWhiteSpace([string]$_.timestampUtc)) { 1 } else { 0 } } }, @{ Expression={ [string]$_.timestampUtc } }, @{ Expression={ [int]$_.sequence } })
$nonStatusLimit = [Math]::Max(0, $Tail - $currentStatusEntry.Count)
if ($orderedEntries.Count -gt $nonStatusLimit) { $orderedEntries = @($orderedEntries | Select-Object -Last $nonStatusLimit) }
$orderedEntries = @($orderedEntries) + @($currentStatusEntry)

[pscustomobject][ordered]@{
    TaskId = $TaskId
    AgentId = $AgentId
    Status = $statusValue
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Entries = @($orderedEntries)
    ActivityPath = $activityPath
}
