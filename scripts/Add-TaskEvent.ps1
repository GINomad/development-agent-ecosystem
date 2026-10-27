[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $Actor,
    [Parameter(Mandatory)][ValidateSet('task-created','task-close-requested','task-closed','task-reopened','workflow-status','agent-status','agent-failure','user-comment','user-comment-acknowledged','agent-routing-request','routing-decision','workflow-input-routed','context-issued','agent-result','continuation-requested','continuation-reconciled','question-opened','question-resolved','review-question-opened','review-question-answered','scope-held','scope-released','review-decision','tech-debt-created','provider-switched','provider-limit-fallback','external-action','pipeline-analysis','pipeline-remediation-request','pr-status','knowledge-update-requested','knowledge-updated')][string] $Type,
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
    $partialKnowledgeResult = $false
    if ($Actor -eq 'knowledge_keeper' -and [string]$task.status -ne 'completed' -and
        (-not $task.PSObject.Properties['closure'] -or [string]$task.closure.status -notin @('knowledge-update-pending','completed')) -and
        $task.PSObject.Properties['workflowAttemptId'] -and -not [string]::IsNullOrWhiteSpace([string]$task.workflowAttemptId) -and
        $task.PSObject.Properties['workflowAttemptAgentId'] -and [string]$task.workflowAttemptAgentId -eq 'knowledge_keeper') {
        $knowledgeUpdatePath = Join-Path $taskRoot 'knowledge-update.json'
        $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
        if ((Test-Path -LiteralPath $knowledgeUpdatePath -PathType Leaf) -and (Test-Path -LiteralPath $ledgerPath -PathType Leaf) -and $Artifact -and
            [IO.Path]::GetFullPath($Artifact).Equals([IO.Path]::GetFullPath($knowledgeUpdatePath),[StringComparison]::OrdinalIgnoreCase)) {
            $expectedEvidence = [Collections.Generic.List[string]]::new()
            foreach ($value in @('agent:knowledge_keeper','knowledge-publication:partial','task-summary:not-created','final-publication:deferred',"knowledge-update-sha256:$(Get-EcosystemFileSha256 -Path $knowledgeUpdatePath)","execution-attempt:$([string]$task.workflowAttemptId)")) { $expectedEvidence.Add($value) }
            if ($task.PSObject.Properties['executionRunId'] -and -not [string]::IsNullOrWhiteSpace([string]$task.executionRunId)) { $expectedEvidence.Add("execution-run:$([string]$task.executionRunId)") }
            if ($task.PSObject.Properties['workspaceLeaseId'] -and -not [string]::IsNullOrWhiteSpace([string]$task.workspaceLeaseId)) { $expectedEvidence.Add("workspace-lease:$([string]$task.workspaceLeaseId)") }
            $hasExpectedEvidence = {
                param([string[]] $CandidateEvidence)
                foreach ($value in $expectedEvidence) { if ($value -notin @($CandidateEvidence)) { return $false } }
                return $true
            }
            $partialKnowledgeResult = (& $hasExpectedEvidence @($Evidence)) -and @(
                Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object {
                    [string]$_.type -eq 'knowledge-updated' -and [string]$_.actor -eq 'knowledge_keeper' -and $_.artifact -and
                    [IO.Path]::GetFullPath([string]$_.artifact).Equals([IO.Path]::GetFullPath($knowledgeUpdatePath),[StringComparison]::OrdinalIgnoreCase) -and
                    (& $hasExpectedEvidence @($_.evidence))
                }
            ).Count -gt 0
        }
    }
    foreach ($requiredName in @($knownAgent.requiredArtifacts)) {
        if ($partialKnowledgeResult -and [string]$requiredName -eq 'task-summary.json') { continue }
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
Add-EcosystemUtf8Line -Path $ledgerPath -Line ($event | ConvertTo-Json -Depth 8 -Compress)
[pscustomobject]$event
