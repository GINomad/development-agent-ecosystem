[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [ValidateSet('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor','health_check')][string] $TargetAgentId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$agentIds = @($config.agents | ForEach-Object { [string]$_.id })
if ($TargetAgentId -and $TargetAgentId -notin $agentIds) { throw "Unknown target agent '$TargetAgentId'." }

$statusMap = [ordered]@{}
foreach ($agentId in $agentIds) {
    $state = if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$agentId]) { $task.agentStatuses.$agentId } else { $null }
    $statusMap[$agentId] = if ($state) { [string]$state.status } else { 'pending' }
}

$unfinished = [Collections.Generic.List[string]]::new()
if ($TargetAgentId) {
    $unfinished.Add($TargetAgentId)
}
else {
    foreach ($agentId in @('requirements_analyst','developer','reviewer','pipeline_monitor')) {
        $status = [string]$statusMap[$agentId]
        if ($status -eq 'completed') { continue }
        $unfinished.Add($agentId)
    }
    $healthStatus = [string]$statusMap['health_check']
    if ($healthStatus -in @('running','waiting','failed')) { $unfinished.Add('health_check') }
}
$preserved = @($agentIds | Where-Object { $_ -notin @($unfinished) -and [string]$statusMap[$_] -in @('completed','skipped') })

$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
$events = @()
if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    $events = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}
$acknowledged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($ack in @($events | Where-Object { $_.type -eq 'user-comment-acknowledged' })) {
    foreach ($value in @($ack.evidence)) { if ($value) { $null = $acknowledged.Add([string]$value) } }
}
$unacknowledgedComments = @($events | Where-Object { $_.type -eq 'user-comment' -and -not $acknowledged.Contains([string]$_.eventId) })
$applicableComments = if ($TargetAgentId) {
    @($unacknowledgedComments | Where-Object { -not $_.PSObject.Properties['targetAgentId'] -or [string]::IsNullOrWhiteSpace([string]$_.targetAgentId) -or [string]$_.targetAgentId -eq $TargetAgentId })
} else { @($unacknowledgedComments) }

$artifactIndexPath = Join-Path $taskRoot 'resume-artifact-index.json'
$previousFingerprints = @{}
if (Test-Path -LiteralPath $artifactIndexPath -PathType Leaf) {
    try {
        $previousIndex = Get-Content -LiteralPath $artifactIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($previousIndex.PSObject.Properties['fingerprints']) {
            foreach ($property in $previousIndex.fingerprints.PSObject.Properties) { $previousFingerprints[$property.Name] = [string]$property.Value }
        }
    }
    catch { $previousFingerprints = @{} }
}
$shareableArtifacts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$null = $shareableArtifacts.Add('assigned-task-context.json')
$null = $shareableArtifacts.Add('review-decisions.json')
foreach ($agent in @($config.agents)) {
    $agentId = [string]$agent.id
    if ([string]$statusMap[$agentId] -ne 'completed') { continue }
    foreach ($requiredName in @($agent.requiredArtifacts)) {
        if ([string]$requiredName -ne 'task-ledger.jsonl') { $null = $shareableArtifacts.Add([string]$requiredName) }
    }
}
$currentFingerprints = [ordered]@{}
$changedArtifacts = [Collections.Generic.List[string]]::new()
$unchangedArtifacts = [Collections.Generic.List[string]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $taskRoot -File | Where-Object { $shareableArtifacts.Contains($_.Name) } | Sort-Object Name)) {
    $fingerprint = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $currentFingerprints[$file.Name] = $fingerprint
    if ($previousFingerprints.ContainsKey($file.Name) -and $previousFingerprints[$file.Name] -eq $fingerprint) { $unchangedArtifacts.Add($file.Name) }
    else { $changedArtifacts.Add($file.Name) }
}
$artifactIndex = [ordered]@{ taskId=$TaskId; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); fingerprints=[pscustomobject]$currentFingerprints }
Write-Utf8NoBom -Path $artifactIndexPath -Content (($artifactIndex | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

[pscustomobject][ordered]@{
    TaskId = $TaskId
    Mode = if ($TargetAgentId) { 'targeted-agent' } else { 'checkpoint' }
    TargetAgentId = if ($TargetAgentId) { $TargetAgentId } else { $null }
    TaskStatus = [string]$task.status
    HasWork = $unfinished.Count -gt 0
    UnfinishedAgentIds = @($unfinished)
    PreservedAgentIds = @($preserved)
    AgentStatuses = [pscustomobject]$statusMap
    ApplicableCommentIds = @($applicableComments | ForEach-Object { [string]$_.eventId })
    ChangedArtifactNames = @($changedArtifacts)
    UnchangedArtifactNames = @($unchangedArtifacts)
    ArtifactIndexPath = $artifactIndexPath
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
}
