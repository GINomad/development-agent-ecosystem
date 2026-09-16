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
$runtimeProvider = Get-AgentRuntimeProvider -Config $config

$knowledge = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$agents = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install
$review = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$mcpHealth = & (Join-Path $PSScriptRoot 'Test-McpServerHealth.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$mcpHealth.Healthy) { throw "Configured local MCP server is unhealthy: $($mcpHealth.Reason)" }
$claudeCli = Resolve-ClaudeCliPath
if (-not $claudeCli) { throw 'Claude Code CLI was not found. Install and authenticate it before running the installer.' }
$registeredMcp = [Collections.Generic.List[object]]::new()
function Test-ClaudeMcpRegistration {
    param([Parameter(Mandatory)][string] $Name)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $details = @(& $claudeCli mcp get $Name 2>$null)
        $exitCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($exitCode -eq 0) {
        $registeredMcp.Add([pscustomobject]@{ name=$Name; details=@($details) })
        return $true
    }
    return $false
}
if ($ConfirmMcpRegistration) {
    if (-not (Test-ClaudeMcpRegistration -Name 'ecosystem-read')) {
        $localScript = Resolve-EcosystemPath -Value ([string]$config.mcp.localServer.arguments[-1]) -Config $config -CodexHome $CodexHome
        & $claudeCli mcp add --transport stdio --scope user ecosystem-read -- powershell -NoProfile -File $localScript
        if ($LASTEXITCODE -ne 0) { throw 'Unable to register local ecosystem-read MCP server.' }
        if (-not (Test-ClaudeMcpRegistration -Name 'ecosystem-read')) { throw 'Claude MCP registration could not be verified after local registration.' }
    }
}
elseif (Test-ClaudeMcpRegistration -Name 'ecosystem-read') { }
foreach ($external in @($config.mcp.servers)) {
    if (-not (Test-ClaudeMcpRegistration -Name ([string]$external.name))) { throw "Configured external MCP server '$($external.name)' is not registered in Claude Code." }
}
$tests = & (Join-Path $PSScriptRoot 'Test-AgentEcosystem.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome

$pluginResult = $null
if (-not $SkipPlugin) {
    & $claudeCli plugin validate $root
    if ($LASTEXITCODE -ne 0) { throw 'Claude marketplace validation failed.' }
    $marketplaceResponse = & $claudeCli plugin marketplace list --json | ConvertFrom-Json
    $marketplaces = if ($marketplaceResponse.PSObject.Properties['marketplaces']) { @($marketplaceResponse.marketplaces) } else { @($marketplaceResponse) }
    if (-not @($marketplaces | Where-Object { [string]$_.name -eq 'development-agent-ecosystem' }).Count) {
        & $claudeCli plugin marketplace add $root --scope user
        if ($LASTEXITCODE -ne 0) { throw 'Unable to add the local Claude plugin marketplace.' }
    }
    & $claudeCli plugin install 'development-agent-ecosystem@development-agent-ecosystem' --scope user
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install the Claude development-agent-ecosystem plugin.' }
    $pluginResult = [pscustomobject]@{ provider='claude'; plugin='development-agent-ecosystem@development-agent-ecosystem'; scope='user' }
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
