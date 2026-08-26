[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $CompletedAgentId,
    [switch] $ElevatedApproved,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.workflow.orchestration.outcomeDrivenTransitions) {
    throw 'Outcome-driven Orchestrator transitions are disabled.'
}

$parameters = @{
    TaskId = $TaskId
    CompletedAgentId = $CompletedAgentId
    OrchestratorAuthorized = $true
    PrepareOnly = [bool]$PrepareOnly
    ConfigPath = $ConfigPath
    CodexHome = $CodexHome
}
if ($ElevatedApproved -or [bool]$config.workflow.automaticContinuation.useElevatedExecution) {
    $parameters.ElevatedApproved = $true
}
& (Join-Path $PSScriptRoot 'Continue-AgentChain.ps1') @parameters
