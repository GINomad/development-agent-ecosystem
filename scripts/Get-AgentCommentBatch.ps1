[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
} else { @() }
$acknowledged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($ack in @($events | Where-Object { $_.type -eq 'user-comment-acknowledged' })) {
    foreach ($eventId in @($ack.evidence)) { if ($eventId) { $null = $acknowledged.Add([string]$eventId) } }
}
$comments = @($events | Where-Object {
    [string]$_.type -in @('user-comment','workflow-input-routed') -and
    -not $acknowledged.Contains([string]$_.eventId) -and
    (-not $_.PSObject.Properties['targetAgentId'] -or [string]::IsNullOrWhiteSpace([string]$_.targetAgentId) -or [string]$_.targetAgentId -eq $AgentId)
} | Sort-Object timestampUtc | ForEach-Object {
    [pscustomobject][ordered]@{
        eventId = [string]$_.eventId
        timestampUtc = [string]$_.timestampUtc
        author = [string]$_.actor
        text = [string]$_.summary
        eventType = [string]$_.type
        sourceEventId = if ([string]$_.type -eq 'workflow-input-routed' -and @($_.evidence).Count) { [string]$_.evidence[0] } else { [string]$_.eventId }
        targetAgentId = if ($_.PSObject.Properties['targetAgentId']) { [string]$_.targetAgentId } else { $null }
        evidence = @($_.evidence)
    }
})
[pscustomobject][ordered]@{
    taskId = $TaskId
    agentId = $AgentId
    count = $comments.Count
    eventIds = @($comments | ForEach-Object { [string]$_.eventId })
    comments = @($comments)
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
}
