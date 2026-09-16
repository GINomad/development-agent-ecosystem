[CmdletBinding()]
param([Parameter(Mandatory)][string] $TaskId,[Parameter(Mandatory)][string] $AgentId,[string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string] $CodexHome)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not(Get-Command Get-EcosystemStateRoot -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Global}
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if ([string]$config.mcp.defaultMode -ne 'allowlist') { return [pscustomobject]@{Mode='classic';Reason='default-disabled';Servers=@()} }
$stateRoot=Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$policy=@($config.mcp.rolePolicies.$AgentId)
$allowed=@($policy|ForEach-Object{if($_ -is [string]){[string]$_}else{[string]$_.server}})
$servers=@()
if (-not [bool]$config.mcp.enabled -or -not $allowed.Count) { return [pscustomobject]@{Mode='classic';Reason='policy-disabled';Servers=@()} }
$allServers=@($config.mcp.localServer)+@($config.mcp.servers)
foreach ($server in $allServers) {
 if ([string]$server.name -notin $allowed) { continue }
 $circuit=Join-Path $stateRoot ('health\mcp\'+[string]$server.name+'.json')
 $open=$false
 if (Test-Path -LiteralPath $circuit) { try { $state=Get-Content -LiteralPath $circuit -Raw -Encoding UTF8|ConvertFrom-Json; $claimId=$TaskId+'-'+$AgentId; if([string]$state.state -eq 'open'){if([DateTime]::Parse([string]$state.retryAfterUtc) -gt [DateTime]::UtcNow){$open=$true}else{$open=-not (& (Join-Path $PSScriptRoot 'Claim-McpCanary.ps1') -ServerName ([string]$server.name) -ClaimId $claimId -ConfigPath $ConfigPath -CodexHome $CodexHome)}}elseif([string]$state.state -eq 'half-open'){$open=if([string]::IsNullOrWhiteSpace([string]$state.canaryClaimId)){-not (& (Join-Path $PSScriptRoot 'Claim-McpCanary.ps1') -ServerName ([string]$server.name) -ClaimId $claimId -ConfigPath $ConfigPath -CodexHome $CodexHome)}else{[string]$state.canaryClaimId -ne $claimId}} } catch { $open=$true } }
 if (-not $open) { $server | Add-Member -NotePropertyName roleTools -NotePropertyValue @($policy|Where-Object{[string]$_.server -eq [string]$server.name}|ForEach-Object{@($_.tools)}) -Force; $servers += $server }
}
if (-not $servers.Count) { return [pscustomobject]@{Mode='classic-after-mcp-failure';Reason='circuit-open-or-no-server';Servers=@()} }
[pscustomobject]@{Mode='mcp';Reason='healthy';Servers=@($servers)}
