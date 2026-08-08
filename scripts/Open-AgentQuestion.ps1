[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateSet('knowledge_keeper','requirements_analyst','developer','reviewer','pipeline_monitor','health_check')][string] $AgentId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Question,
    [string] $Stage = 'waiting_for_input',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$questionText = $Question.Trim()
if (-not $questionText) { throw 'Question cannot be empty.' }
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskPath = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId\task.json"
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type 'question-opened' -Summary $questionText -ConfigPath $ConfigPath -CodexHome $CodexHome
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status waiting_for_input -AgentId $AgentId -AgentStatus waiting -Stage $Stage -Message $questionText -Actor $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{
    TaskId = $TaskId
    QuestionId = [string]$event.eventId
    AgentId = $AgentId
    Question = $questionText
    TimestampUtc = [string]$event.timestampUtc
}
