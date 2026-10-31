[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $HostConfigPath,
    [Parameter(Mandatory)][string] $TaskConfigPath,
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$hostConfig = Get-EcosystemConfig -ConfigPath $HostConfigPath -CodexHome $CodexHome
$taskConfig = Get-EcosystemConfig -ConfigPath $TaskConfigPath -CodexHome $CodexHome
$hostStateRoot = [IO.Path]::GetFullPath((Get-EcosystemStateRoot -Config $hostConfig -CodexHome $CodexHome))
$taskStateRoot = [IO.Path]::GetFullPath((Get-EcosystemStateRoot -Config $taskConfig -CodexHome $CodexHome))
if ($hostStateRoot -ne $taskStateRoot) { throw 'The task configuration must resolve to the same state root as the host configuration.' }
$taskPath = Join-Path $hostStateRoot "tasks\$TaskId\task.json"
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found under the host configuration state root." }
if ($PSCmdlet.ShouldProcess($TaskId, 'bind trusted task configuration')) {
    & (Join-Path $PSScriptRoot 'Write-TaskConfigBinding.ps1') -TaskId $TaskId -ConfigPath $TaskConfigPath -CodexHome $CodexHome
}
