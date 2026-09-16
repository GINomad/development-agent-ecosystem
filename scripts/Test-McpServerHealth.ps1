[CmdletBinding()]
param([string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string] $CodexHome,[string] $ServerName='ecosystem-read')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not(Get-Command Get-EcosystemStateRoot -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Global}
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$server=@($config.mcp.localServer)+@($config.mcp.servers)|Where-Object {[string]$_.name -eq $ServerName}|Select-Object -First 1
if (-not $server) { throw "Unknown MCP server '$ServerName'." }
if ($ServerName -ne 'ecosystem-read') { return [pscustomobject]@{Server=$ServerName;Healthy=$false;Reason='external-probes-are-observation-only'} }
$scriptPath=Resolve-EcosystemPath -Value ([string]$server.arguments[-1]) -Config $config -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { return [pscustomobject]@{Server=$ServerName;Healthy=$false;Reason='local-server-script-missing'} }
$probe=@(& $scriptPath -Probe 2>&1);[pscustomobject]@{Server=$ServerName;Healthy=($LASTEXITCODE -eq 0 -and ($probe -join "`n") -match 'healthy');Reason=($probe -join ' ')}
