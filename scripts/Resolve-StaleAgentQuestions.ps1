[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][datetime] $RestartedAtUtc,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$events = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
else { @() }

$closedQuestionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($event in @($events | Where-Object { [string]$_.type -eq 'question-resolved' })) {
    foreach ($evidenceValue in @($event.evidence)) { if ($evidenceValue) { $null = $closedQuestionIds.Add([string]$evidenceValue) } }
}
$restartUtc = $RestartedAtUtc.ToUniversalTime()
$openAgentQuestions = @($events | Where-Object {
    [string]$_.type -eq 'question-opened' -and [string]$_.actor -eq $AgentId -and
    -not $closedQuestionIds.Contains([string]$_.eventId)
})
$priorQuestions = @($openAgentQuestions | Where-Object { [DateTime]::Parse([string]$_.timestampUtc).ToUniversalTime() -lt $restartUtc })
$newQuestions = @($openAgentQuestions | Where-Object { [DateTime]::Parse([string]$_.timestampUtc).ToUniversalTime() -ge $restartUtc })
$agentStatus = if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$AgentId]) { [string]$task.agentStatuses.$AgentId.status } else { 'pending' }
$stillWaitingForPriorQuestion = [string]$task.status -eq 'waiting_for_input' -and $agentStatus -eq 'waiting' -and $newQuestions.Count -eq 0

$resolvedIds = [Collections.Generic.List[string]]::new()
if (-not $stillWaitingForPriorQuestion) {
    foreach ($question in $priorQuestions) {
        $questionId = [string]$question.eventId
        $summary = "Question $questionId from '$AgentId' was superseded after a successful targeted restart because the agent no longer requires that prior input."
        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor ecosystem -Type question-resolved -Summary $summary -Artifact $taskPath -Evidence @($questionId, "targeted-restart:$($restartUtc.ToString('o'))") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        $resolvedIds.Add($questionId)
    }
}

[pscustomobject][ordered]@{
    TaskId = $TaskId
    AgentId = $AgentId
    RestartedAtUtc = $restartUtc.ToString('o')
    SupersededQuestionIds = @($resolvedIds)
    PreservedQuestionIds = if ($stillWaitingForPriorQuestion) { @($priorQuestions | ForEach-Object { [string]$_.eventId }) } else { @() }
    CurrentQuestionIds = @($newQuestions | ForEach-Object { [string]$_.eventId })
}
