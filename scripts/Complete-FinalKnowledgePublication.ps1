[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$decision = & (Join-Path $PSScriptRoot 'Test-FinalKnowledgePublication.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$decision.Eligible) {
    return [pscustomobject][ordered]@{ TaskId=$TaskId; Completed=$false; Decision=$decision }
}
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$task.status -ne 'completed') {
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status completed -Stage knowledge_published -Message 'Knowledge Keeper published the validated final task summary; task finalization is complete.' -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor knowledge_keeper -Type task-closed -Summary 'Task completed after the validated final Knowledge Keeper publication.' -Artifact (Join-Path $taskRoot 'task-summary.json') -Evidence @("knowledge-publication-event:$([string]$decision.OutcomeEventId)", "task-summary-sha256:$([string]$decision.SummarySha256)") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
[pscustomobject][ordered]@{ TaskId=$TaskId; Completed=$true; Decision=$decision }
