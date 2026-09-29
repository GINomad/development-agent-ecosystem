[CmdletBinding()]
param(
    [string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\no-codex-install')
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$testConfigPath=Join-Path $OutputRoot 'agents.json'
$testCodexHome=Join-Path $OutputRoot 'empty-codex-home'
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
foreach($agent in @($config.agents)){$agent.provider='copilot'}
$config.runtime.stateRoot=Join-Path $OutputRoot 'state'
$config.runtime.agentInstallRoot=Join-Path $OutputRoot 'must-not-be-created\agents'
$config.knowledge.technicalRoot=Join-Path $OutputRoot 'knowledge\global'
foreach($project in @($config.projects)){$project.domainKnowledgeRoot=Join-Path $OutputRoot ('knowledge\projects\'+[string]$project.id)}
Write-Utf8NoBom -Path $testConfigPath -Content (($config|ConvertTo-Json -Depth 100)+[Environment]::NewLine)

$result=& (Join-Path $root 'scripts\Install-AgentEcosystem.ps1') -ConfigPath $testConfigPath -CodexHome $testCodexHome -ValidationOutputRoot (Join-Path $OutputRoot 'validation') -SkipPlugin
if(-not [bool]$result.Installed -or $result.AgentInstallRoot -or $result.Plugin -or @($result.RegisteredMcp).Count -or -not [bool]$result.Tests.Passed){throw 'No-Codex installation did not complete through its provider-aware validation path.'}
if(Test-Path -LiteralPath $config.runtime.agentInstallRoot){throw 'No-Codex installation unexpectedly generated Codex agent definitions.'}

[pscustomobject]@{Passed=$true;ConfigPath=$testConfigPath;CodexHome=$testCodexHome;Providers=@($config.agents.provider|Select-Object -Unique);ValidationChecks=@($result.Tests.Checks).Count}
