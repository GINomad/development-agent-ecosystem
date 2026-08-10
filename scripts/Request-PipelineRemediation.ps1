[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $PipelineResultPath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
if (-not $PipelineResultPath) { $PipelineResultPath = Join-Path $taskRoot 'pipeline-result.json' }
if (-not (Test-Path -LiteralPath $PipelineResultPath -PathType Leaf)) { throw "Pipeline result was not found: $PipelineResultPath" }
$result = Get-Content -LiteralPath $PipelineResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$result.taskId -ne $TaskId) { throw 'Pipeline result belongs to another task.' }

$remediation = $result.remediation
if ([string]$result.overallResult -ne 'non-success' -or [string]$remediation.status -ne 'pending' -or [string]$remediation.targetAgentId -ne 'developer') {
    return [pscustomobject]@{ Requested=$false; Reason=[string]$remediation.reason; Artifact=$null }
}
if ([string]$result.failureClassification.category -notin @('code','test')) { throw 'Only code or test failures may be routed to Developer.' }

$signatureEvidence = "failure-signature:$([string]$remediation.failureSignature)"
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $ledgerPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json
        if ([string]$event.type -eq 'pipeline-remediation-request' -and @($event.evidence) -contains $signatureEvidence) {
            return [pscustomobject]@{ Requested=$false; Reason='An identical remediation request already exists.'; Artifact=[string]$event.artifact }
        }
    }
}

$shortSignature = ([string]$remediation.failureSignature).Substring(0, 16)
$artifactPath = Join-Path $taskRoot "pipeline-remediation-$shortSignature.json"
$failedTasks = @($result.runs | ForEach-Object { @($_.failedTasks) })
$request = [ordered]@{
    taskId = $TaskId
    repositoryId = [string]$result.repositoryId
    branch = [string]$result.branch
    commit = [string]$result.commit
    category = [string]$result.failureClassification.category
    failureSignature = [string]$remediation.failureSignature
    cycle = [int]$remediation.cycle
    maxCycles = [int]$remediation.maxCycles
    pipelineRunIds = @($result.runs | ForEach-Object { [int]$_.id })
    failedTasks = @($failedTasks)
    status = 'pending'
    targetAgentId = 'developer'
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
}
Write-Utf8NoBom -Path $artifactPath -Content (($request | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

$summary = "Pipeline $($request.category) failure on $($request.branch)@$($request.commit.Substring(0, 12)) routed to Developer (cycle $($request.cycle)/$($request.maxCycles))."
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId developer -AgentStatus pending -Stage pipeline_remediation_pending -Message $summary -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type pipeline-remediation-request -Summary $summary -Artifact $artifactPath -Evidence @($PipelineResultPath, $signatureEvidence) -TargetAgentId developer -ConfigPath $ConfigPath -CodexHome $CodexHome
[pscustomobject]@{ Requested=$true; Reason=$summary; Artifact=$artifactPath; EventId=[string]$event.eventId }
