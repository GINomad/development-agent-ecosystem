[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
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
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$agentState = if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$AgentId]) { $task.agentStatuses.$AgentId } else { $null }
$agentStatus = if ($agentState) { [string]$agentState.status } else { 'pending' }
$terminalStatuses = @('completed','waiting','failed','skipped')
if ($agentStatus -notin $terminalStatuses) {
    throw "Targeted agent '$AgentId' host run ended without a terminal agent status; current status is '$agentStatus'. No background agent remains after codex exec exits."
}
[pscustomobject]@{ TaskId=$TaskId; AgentId=$AgentId; AgentStatus=$agentStatus; TaskStatus=[string]$task.status; Terminal=$true }
