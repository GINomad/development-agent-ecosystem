[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $Actor,
    [Parameter(Mandatory)][ValidateSet('task-created','task-close-requested','task-closed','task-reopened','workflow-status','agent-status','agent-failure','user-comment','user-comment-acknowledged','agent-routing-request','routing-decision','workflow-input-routed','context-issued','agent-result','continuation-requested','continuation-reconciled','question-opened','question-resolved','review-question-opened','review-question-answered','scope-held','scope-released','review-decision','tech-debt-created','external-action','pipeline-analysis','pipeline-remediation-request','pr-status','knowledge-update-requested','knowledge-updated')][string] $Type,
    [Parameter(Mandatory)][string] $Summary,
    [string] $Artifact,
    [string[]] $Evidence = @(),
    [AllowNull()][object] $HumanIntervention,
    [ValidatePattern('^[a-z][a-z0-9_]*$')][string] $TargetAgentId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ($Type -eq 'question-opened' -and $null -eq $HumanIntervention) { throw 'A question-opened event requires structured human-intervention guidance.' }
if ($Type -ne 'question-opened' -and $null -ne $HumanIntervention) { throw 'Human-intervention guidance is valid only for question-opened events.' }
if ($TargetAgentId -and -not @($config.agents | Where-Object { [string]$_.id -eq $TargetAgentId }).Count) { throw "Unknown target agent '$TargetAgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
$knownAgent = @($config.agents | Where-Object { [string]$_.id -eq $Actor }) | Select-Object -First 1
if ($Type -eq 'agent-result' -and $knownAgent) {
    $taskPath = Join-Path $taskRoot 'task.json'
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw 'An agent outcome requires an existing task.' }
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentState = if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$Actor]) { $task.agentStatuses.$Actor } else { $null }
    if (-not $agentState -or [string]$agentState.status -ne 'completed') { throw "Agent '$Actor' cannot publish an outcome before successful completion." }
    foreach ($requiredName in @($knownAgent.requiredArtifacts)) {
        $requiredPath = Join-Path $taskRoot ([string]$requiredName)
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Agent '$Actor' cannot publish without required artifact '$requiredName'." }
        if ([string]$requiredName -like '*.json') { $null = Get-Content -LiteralPath $requiredPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        elseif ([string]$requiredName -like '*.jsonl') {
            foreach ($requiredLine in Get-Content -LiteralPath $requiredPath -Encoding UTF8) {
                if (-not [string]::IsNullOrWhiteSpace($requiredLine)) { $null = $requiredLine | ConvertFrom-Json }
            }
        }
    }
}
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
$event = [ordered]@{
    eventId = [guid]::NewGuid().ToString('N')
    taskId = $TaskId
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    actor = $Actor
    type = $Type
    summary = $Summary
    artifact = if ($Artifact) { $Artifact } else { $null }
    evidence = @($Evidence)
    targetAgentId = if ($TargetAgentId) { $TargetAgentId } else { $null }
}
if ($null -ne $HumanIntervention) { $event.humanIntervention = $HumanIntervention }
$line = ($event | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
$stream = [IO.File]::Open($ledgerPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
[pscustomobject]$event
