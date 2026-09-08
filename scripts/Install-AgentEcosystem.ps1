[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome,
    [switch] $MigrateScheduledTasks,
    [switch] $SkipPlugin,
    [switch] $ConfirmMcpRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$root = Get-EcosystemRoot
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome

$knowledge = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$agents = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install
$review = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$mcpHealth = & (Join-Path $PSScriptRoot 'Test-McpServerHealth.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$mcpHealth.Healthy) { throw "Configured local MCP server is unhealthy: $($mcpHealth.Reason)" }
$codexCliPath=Resolve-CodexCliPath
if(-not $codexCliPath){throw 'Codex CLI was not found for MCP inventory validation.'}
try{$mcpInventory=& $codexCliPath mcp list --json 2>$null;if($LASTEXITCODE -ne 0 -or -not $mcpInventory){throw 'empty inventory'};$mcpInventory=$mcpInventory|ConvertFrom-Json;$registeredMcp=if($mcpInventory.PSObject.Properties['servers']){@($mcpInventory.servers)}else{@($mcpInventory)}}catch{throw 'Codex MCP inventory cannot be verified; installation is denied.'}
if ($ConfirmMcpRegistration) {
    $local = @($registeredMcp | Where-Object { [string]$_.name -eq 'ecosystem-read' })
    if (-not $local.Count) {
        $localScript = Resolve-EcosystemPath -Value ([string]$config.mcp.localServer.arguments[-1]) -Config $config -CodexHome $CodexHome
        & $codexCliPath mcp add ecosystem-read -- powershell -NoProfile -File $localScript
        if ($LASTEXITCODE -ne 0) { throw 'Unable to register local ecosystem-read MCP server.' }
        try{$mcpInventory=& $codexCliPath mcp list --json 2>$null;if($LASTEXITCODE -ne 0 -or -not $mcpInventory){throw 'empty inventory'};$mcpInventory=$mcpInventory|ConvertFrom-Json;$registeredMcp=if($mcpInventory.PSObject.Properties['servers']){@($mcpInventory.servers)}else{@($mcpInventory)}}catch{throw 'Codex MCP inventory cannot be verified after local registration.'}
    }
}
foreach($external in @($config.mcp.servers)){if(-not @($registeredMcp|Where-Object{[string]$_.name -eq [string]$external.name}).Count){throw "Configured external MCP server '$($external.name)' is not registered in Codex."}}
$tests = & (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome

$pluginResult = $null
if (-not $SkipPlugin) {
    $marketplaceResponse = & codex plugin marketplace list --json | ConvertFrom-Json
    $marketplaces = @($marketplaceResponse.marketplaces)
    if (-not @($marketplaces | Where-Object { $_.name -eq 'personal' -and [IO.Path]::GetFullPath([string]$_.root) -eq [IO.Path]::GetFullPath($root) }).Count) {
        & codex plugin marketplace add $root --json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to add the local personal plugin marketplace.' }
    }
    $pluginList = & codex plugin list --json | ConvertFrom-Json
    $installedPlugin = @($pluginList.installed | Where-Object { $_.pluginId -eq 'development-agent-ecosystem@personal' }) | Select-Object -First 1
    if ($installedPlugin) {
        $pluginResult = $installedPlugin
    }
    else {
        $pluginResult = & codex plugin add 'development-agent-ecosystem@personal' --json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to install development-agent-ecosystem plugin.' }
    }
}

$scheduleResult = $null
if ($MigrateScheduledTasks) {
    $scheduleResult = & (Join-Path $PSScriptRoot 'Install-EcosystemScheduledTasks.ps1') -Action Install -ConfigPath $ConfigPath -CodexHome $CodexHome
}

[pscustomobject]@{
    Installed = $true
    RepositoryRoot = $root
    AgentInstallRoot = $agents.OutputDirectory
    Knowledge = $knowledge
    Review = $review
    McpHealth = $mcpHealth
    RegisteredMcp = $registeredMcp
    Tests = $tests
    Plugin = $pluginResult
    Schedule = $scheduleResult
    DashboardCommand = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Start-AgentDashboard.ps1')`""
}
