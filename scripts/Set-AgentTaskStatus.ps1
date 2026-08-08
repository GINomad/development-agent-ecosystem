[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [ValidateSet('created','queued','running','waiting_for_input','held','review_pending','completed','failed','interrupted')][string] $Status,
    [ValidateSet('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor')][string] $AgentId,
    [ValidateSet('pending','running','waiting','completed','failed','skipped')][string] $AgentStatus,
    [string] $Stage,
    [string] $Message,
    [int] $ProcessId,
    [string] $Actor = 'ecosystem',
    [switch] $AcknowledgeComments,
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
if (-not $Status -and -not $AgentId -and -not $Stage -and -not $Message -and -not $AcknowledgeComments) {
    throw 'Specify a task status, agent status, stage, message, or comment acknowledgement.'
}
if ([bool]$AgentId -xor [bool]$AgentStatus) { throw 'AgentId and AgentStatus must be supplied together.' }

$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$now = [DateTime]::UtcNow.ToString('o')
if ($Status) { $task | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force }
if ($Stage) { $task | Add-Member -NotePropertyName currentStage -NotePropertyValue $Stage -Force }
if ($Message) { $task | Add-Member -NotePropertyName lastMessage -NotePropertyValue $Message -Force }
if ($ProcessId -gt 0) { $task | Add-Member -NotePropertyName workflowProcessId -NotePropertyValue $ProcessId -Force }
if ($AcknowledgeComments) { $task | Add-Member -NotePropertyName hasUnreadUserComments -NotePropertyValue $false -Force }
$task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force

if (-not $task.PSObject.Properties['agentStatuses']) {
    $task | Add-Member -NotePropertyName agentStatuses -NotePropertyValue ([pscustomobject]@{})
}
if ($AgentId) {
    $agentValue = [pscustomobject][ordered]@{ status=$AgentStatus; updatedAtUtc=$now; message=if ($Message) { $Message } else { '' } }
    $task.agentStatuses | Add-Member -NotePropertyName $AgentId -NotePropertyValue $agentValue -Force
}

Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

$eventType = if ($AgentId) { 'agent-status' } else { 'workflow-status' }
$eventSummary = if ($Message) { $Message } elseif ($AgentId) { "$AgentId is $AgentStatus." } elseif ($Status) { "Workflow is $Status." } else { 'Workflow state updated.' }
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $Actor -Type $eventType -Summary $eventSummary -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome
[pscustomobject]@{ TaskId=$TaskId; Status=[string]$task.status; AgentId=$AgentId; AgentStatus=$AgentStatus; UpdatedAtUtc=$now; Event=$event }

