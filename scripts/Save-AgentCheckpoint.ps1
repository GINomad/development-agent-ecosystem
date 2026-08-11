[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateSet('running','waiting','failed')][string] $Status,
    [Parameter(Mandatory)][string] $Summary,
    [string] $NextStep,
    [string[]] $EvidenceRefs = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$checkpointRoot = Join-Path $taskRoot 'agent-checkpoints'
New-Item -ItemType Directory -Path $checkpointRoot -Force | Out-Null
$checkpointPath = Join-Path $checkpointRoot "$AgentId.json"
$checkpoint = [ordered]@{
    taskId = $TaskId
    agentId = $AgentId
    status = $Status
    updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    summary = $Summary
    nextStep = if ([string]::IsNullOrWhiteSpace($NextStep)) { $null } else { $NextStep }
    evidenceRefs = @($EvidenceRefs)
    publishedAtUtc = $null
}
Write-Utf8NoBom -Path $checkpointPath -Content (($checkpoint | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
[pscustomobject]@{ TaskId=$TaskId; AgentId=$AgentId; Status=$Status; CheckpointPath=$checkpointPath }
