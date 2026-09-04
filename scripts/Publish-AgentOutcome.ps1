[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][string] $Summary,
    [string[]] $ArtifactNames = @(),
    [string[]] $Evidence = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$agent = @($config.agents | Where-Object { [string]$_.id -eq $AgentId }) | Select-Object -First 1
if (-not $agent) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($AgentId -eq 'knowledge_keeper') {
    if ([string]$task.status -in @('failed','waiting_for_input','held','review_pending')) { throw 'Knowledge Keeper cannot publish a final task outcome while the task is blocked or failed.' }
    $manualClosure = $task.PSObject.Properties['closure'] -and [string]$task.closure.kind -eq 'manual' -and [string]$task.closure.status -eq 'knowledge-update-pending'
    $completedPrClosure = $task.PSObject.Properties['closure'] -and [string]$task.closure.kind -eq 'pr-completed' -and [string]$task.closure.status -in @('knowledge-update-pending','completed')
    if ($completedPrClosure) {
        $pullRequestStatusPath = Join-Path $taskRoot 'pull-request-status.json'
        if (-not (Test-Path -LiteralPath $pullRequestStatusPath -PathType Leaf)) { throw 'Knowledge Keeper cannot publish a completed-PR closure without persisted pull-request-status.json evidence.' }
        $pullRequestStatus = Get-Content -LiteralPath $pullRequestStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$pullRequestStatus.status -ne 'completed') { throw "Knowledge Keeper cannot publish a completed-PR closure while the persisted pull request status is '$([string]$pullRequestStatus.status)'." }
    }
    if (-not $manualClosure -and -not $completedPrClosure) {
        foreach ($deliveryAgentId in @('requirements_analyst','developer','reviewer','review_verifier','pipeline_monitor')) {
            $deliveryState = if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$deliveryAgentId]) { [string]$task.agentStatuses.$deliveryAgentId.status } else { 'pending' }
            if ($deliveryState -ne 'completed') { throw "Knowledge Keeper cannot publish task-summary.json before '$deliveryAgentId' has a successful or validated no-op outcome." }
        }
    }
    $pipelineResultPath = Join-Path $taskRoot 'pipeline-result.json'
    if (Test-Path -LiteralPath $pipelineResultPath -PathType Leaf) {
        $pipelineResult = Get-Content -LiteralPath $pipelineResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$pipelineResult.overallResult -ne 'succeeded') { throw "Knowledge Keeper cannot complete the task while the latest exact-SHA pipeline result is '$([string]$pipelineResult.overallResult)'." }
    }
}
$required = @(@($agent.requiredArtifacts | ForEach-Object { [string]$_ }) + @($ArtifactNames) | Select-Object -Unique)
$validated = [Collections.Generic.List[string]]::new()
$publicationEvidence = [Collections.Generic.List[string]]::new()
foreach ($name in $required) {
    if ([IO.Path]::GetFileName($name) -ne $name) { throw "Outcome artifact must be a direct task artifact: $name" }
    $path = Join-Path $taskRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required outcome artifact is missing: $name" }
    if ($task.PSObject.Properties['reopenedAtUtc'] -and $task.PSObject.Properties['revisionResetAgentIds'] -and $AgentId -in @($task.revisionResetAgentIds)) {
        $reopenedAt = [DateTime]::Parse([string]$task.reopenedAtUtc).ToUniversalTime()
        if ((Get-Item -LiteralPath $path).LastWriteTimeUtc -le $reopenedAt) { throw "Outcome artifact '$name' was not refreshed for task revision $([int]$task.revision)." }
    }
    if ([IO.Path]::GetExtension($name).Equals('.json', [StringComparison]::OrdinalIgnoreCase)) {
        $parsedArtifact = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        & (Join-Path $PSScriptRoot 'Test-AgentOutcomeArtifact.ps1') -TaskId $TaskId -AgentId $AgentId -ArtifactName $name -Path $path -TaskRoot $taskRoot
        if ($name -eq 'task-summary.json') {
            if ([string]$parsedArtifact.taskId -ne $TaskId -or [string]$parsedArtifact.status -ne 'completed') { throw 'task-summary.json must identify this task and have status completed.' }
            foreach ($propertyName in @('completedAtUtc','repositories','outcomes','decisions','verification','knowledgeUpdates','artifacts','residualItems')) {
                if (-not $parsedArtifact.PSObject.Properties[$propertyName]) { throw "task-summary.json is missing '$propertyName'." }
            }
        }
    }
    elseif ($name.EndsWith('.jsonl', [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $null = $line | ConvertFrom-Json }
        }
    }
    $validated.Add($path)
}

if ($AgentId -eq 'reviewer') {
    $snapshot = & (Join-Path $PSScriptRoot 'Save-ReviewArtifactSnapshot.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
    $publicationEvidence.Add([string]$snapshot.IndexPath)
    $publicationEvidence.Add([string]$snapshot.SnapshotPath)
}

$primaryArtifact = if ($validated.Count) { $validated[$validated.Count - 1] } else { $null }
$continuationRequest = $null
if ([bool]$config.workflow.automaticContinuation.enabled -and $AgentId -in @('orchestrator','requirements_analyst','developer','reviewer','review_verifier','pipeline_monitor','health_check')) {
    $requestId = [guid]::NewGuid().ToString('N')
    $continuationRequest = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type continuation-requested -Summary "Successful '$AgentId' outcome is returned to Orchestrator for the next deterministic decision." -Artifact $primaryArtifact -Evidence @("continuation-request:$requestId", "completed-agent:$AgentId") -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome
}

& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId $AgentId -AgentStatus completed -Stage "$AgentId-completed" -Message $Summary -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$continuationEvidence = if ($continuationRequest) { @("continuation-event:$([string]$continuationRequest.eventId)") } else { @() }
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type agent-result -Summary $Summary -Artifact $primaryArtifact -Evidence (@($validated) + @($publicationEvidence) + @($Evidence) + $continuationEvidence) -ConfigPath $ConfigPath -CodexHome $CodexHome
$checkpointPath = Join-Path (Join-Path $taskRoot 'agent-checkpoints') "$AgentId.json"
if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
    $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $checkpoint | Add-Member -NotePropertyName publishedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $checkpoint | Add-Member -NotePropertyName outcomeEventId -NotePropertyValue ([string]$event.eventId) -Force
    Write-Utf8NoBom -Path $checkpointPath -Content (($checkpoint | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}
[pscustomobject]@{ TaskId=$TaskId; AgentId=$AgentId; EventId=[string]$event.eventId; Artifacts=@($validated) }
