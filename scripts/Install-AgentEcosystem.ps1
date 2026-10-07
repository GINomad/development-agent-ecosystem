[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome,
    [switch] $MigrateScheduledTasks,
    [switch] $SkipPlugin,
    [switch] $ConfirmMcpRegistration,
    [switch] $InteractiveProviderSetup,
    [switch] $ChatOnly,
    [ValidateSet('codex','copilot','claude')][string] $ChatProvider = 'codex',
    [string] $ChatInstallRoot,
    [string] $ValidationOutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$root = Get-EcosystemRoot
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome

if($ChatOnly){
    $parameters=@{Provider=$ChatProvider;ConfigPath=$ConfigPath;CodexHome=$CodexHome}
    if($ChatInstallRoot){$parameters.DestinationRoot=$ChatInstallRoot}
    return & (Join-Path $PSScriptRoot 'Install-ChatOnlyAgents.ps1') @parameters
}

if($InteractiveProviderSetup){
    $rawConfig=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
    Write-Host 'Choose a provider for each agent: codex, copilot, or claude. Press Enter to keep the current value.'
    foreach($agent in @($rawConfig.agents)){
        $current=[string]$agent.provider
        $choice=(Read-Host ("{0} [{1}]" -f [string]$agent.name,$current)).Trim().ToLowerInvariant()
        if(-not $choice){$choice=$current}
        if($choice -notin @('codex','copilot','claude')){throw "Unsupported provider '$choice' for agent '$($agent.id)'."}
        $agent.provider=$choice
    }
    Write-Utf8NoBomAtomic -Path $ConfigPath -Content (($rawConfig|ConvertTo-Json -Depth 100)+[Environment]::NewLine)
    $config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
    $auth=& (Join-Path $PSScriptRoot 'Get-AgentProviderAuth.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
    foreach($provider in @($auth.providers|Where-Object{$_.provider -in @($config.agents.provider|Select-Object -Unique)})){
        Write-Host ("{0}: installed={1}; auth={2}" -f $provider.provider,$provider.installed,$provider.authStatus)
        if($provider.provider -in @('copilot','claude') -and $provider.installed){
            $login=(Read-Host ("Start provider-owned login for {0}? [y/N]" -f $provider.provider)).Trim()
            if($login -match '^(?i:y|yes)$'){& (Join-Path $PSScriptRoot 'Start-AgentProviderLogin.ps1') -Provider ([string]$provider.provider) -ConfigPath $ConfigPath -CodexHome $CodexHome|Out-Null}
        }
    }
}

$knowledge = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$codexSelected=@($config.agents|Where-Object{[string]$_.provider -eq 'codex'}).Count -gt 0
$agents = if($codexSelected){& (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install}else{[pscustomobject]@{Installed=$false;OutputDirectory=$null;AgentFiles=@();Reason='No agent is assigned to Codex.'}}
$review = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$mcpHealth = & (Join-Path $PSScriptRoot 'Test-McpServerHealth.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$mcpHealth.Healthy) { throw "Configured local MCP server is unhealthy: $($mcpHealth.Reason)" }
$registeredMcp=@()
if($codexSelected){
    $codexCliPath=Resolve-CodexCliPath
    if(-not $codexCliPath){throw 'Codex CLI was not found for agents assigned to Codex.'}
    try{$mcpInventory=& $codexCliPath mcp list --json 2>$null;if($LASTEXITCODE -ne 0 -or -not $mcpInventory){throw 'empty inventory'};$mcpInventory=$mcpInventory|ConvertFrom-Json;$registeredMcp=if($mcpInventory.PSObject.Properties['servers']){@($mcpInventory.servers)}else{@($mcpInventory)}}catch{throw 'Codex MCP inventory cannot be verified for agents assigned to Codex; installation is denied.'}
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
}
$validationParameters=@{ConfigPath=$ConfigPath;CodexHome=$CodexHome}
if($ValidationOutputRoot){$validationParameters.OutputRoot=$ValidationOutputRoot}
$tests = @(& (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') @validationParameters)
if ($tests.Count -ne 1 -or -not [bool]$tests[0].Passed) { throw 'Complete ecosystem validation did not return exactly one Passed=true result.' }
$tests = $tests[0]

$pluginResult = $null
if (-not $SkipPlugin -and $codexSelected) {
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
