[CmdletBinding()]
param(
    [string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\provider-routing'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$testConfigPath=Join-Path $OutputRoot 'agents.json'
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
$config.runtime.stateRoot=Join-Path $OutputRoot 'state'
$hostCli=(Get-Command powershell.exe -ErrorAction Stop).Source
$config.providerRouting.providers.copilot.command=$hostCli
$config.providerRouting.providers.claude.command=$hostCli
Write-Utf8NoBom -Path $testConfigPath -Content (($config|ConvertTo-Json -Depth 100)+[Environment]::NewLine)

$expected=[ordered]@{orchestrator='codex';knowledge_keeper='codex';requirements_analyst='codex';developer='copilot';reviewer='copilot';review_verifier='codex';pipeline_monitor='copilot';health_check='codex'}
foreach($entry in $expected.GetEnumerator()){
    $agent=@($config.agents|Where-Object{[string]$_.id -eq $entry.Key}|Select-Object -First 1)
    if(-not $agent -or [string]$agent.provider -ne [string]$entry.Value){throw "Default provider assignment is incorrect for '$($entry.Key)'."}
}

$taskId='provider-route-'+[guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskId -TaskSelector 'Synthetic provider routing test.' -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $testConfigPath|Out-Null
$copilotRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId developer -Tier standard -ConfigPath $testConfigPath
if([string]$copilotRoute.provider -ne 'copilot' -or [string]$copilotRoute.model -ne 'gpt-5' -or [string]$copilotRoute.reasoningEffort -ne 'medium'){throw 'Copilot provider tier mapping failed.'}
& (Join-Path $root 'scripts\Switch-TaskAgentProvider.ps1') -TaskId $taskId -AgentId developer -Provider claude -ConfigPath $testConfigPath|Out-Null
$claudeRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId developer -Tier standard -ConfigPath $testConfigPath
if([string]$claudeRoute.provider -ne 'claude' -or [string]$claudeRoute.model -ne 'sonnet' -or [string]$claudeRoute.reasoningEffort -ne 'none'){throw 'Task-scoped Claude override or tier mapping failed.'}
$taskView=& (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $taskId -IncludeCompleted -ConfigPath $testConfigPath
if([string]$taskView.Tasks[0].AgentStatuses.developer.provider -ne 'claude'){throw 'Task view did not expose the effective provider override.'}
$routingArtifact=Get-Content -LiteralPath (Join-Path $config.runtime.stateRoot "tasks\$taskId\provider-routing.json") -Raw -Encoding UTF8|ConvertFrom-Json
if(@($routingArtifact.decisions).Count -ne 2){throw 'Provider routing decisions were not persisted exactly once per changed route.'}

$workflow=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
$copilot=Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-CopilotRole.ps1') -Raw -Encoding UTF8
$dashboard=Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
$dashboardHost=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
foreach($token in @('Get-CodexMcpOverrides.ps1','additional-mcp-config','--mcp-config','provider-limit-')){if(($workflow+$copilot) -notmatch [regex]::Escape($token)){throw "Provider runtime is missing '$token'."}}
foreach($token in @('agentProviderSelect','switchAgentProvider','Switch-TaskAgentProvider.ps1','/provider')){if(($dashboard+$dashboardHost) -notmatch [regex]::Escape($token)){throw "Dashboard provider switching is missing '$token'."}}

foreach($provider in @('codex','copilot','claude')){
    $installParameters=@{Provider=$provider;DestinationRoot=(Join-Path $OutputRoot ('preview-'+$provider));ConfigPath=$testConfigPath}
    if($provider -ne 'codex'){$installParameters.Preview=$true}
    $preview=& (Join-Path $root 'scripts\Install-ChatOnlyAgents.ps1') @installParameters
    if(@($preview.Written).Count -ne 13 -or [bool]$preview.DashboardInstalled){throw "Chat-only preview for '$provider' is incomplete."}
    if($provider -eq 'codex'){
        $codexAgent=Get-Content -LiteralPath (Join-Path $preview.DestinationRoot 'agents\development_implementer.toml') -Raw -Encoding UTF8
        if($codexAgent -notmatch 'standalone Codex agent-only mode' -or $codexAgent -match 'standalone GitHub Copilot'){throw 'Codex chat-only agent still depends on another provider profile.'}
    }
}
$daily=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$daily.status -ne 'no-incidents' -or $daily.reportPath){throw 'A clean daily health scan was not a true no-op.'}
$taskRoot=Join-Path $config.runtime.stateRoot ('tasks\'+$taskId)
$dailyLog=Join-Path $taskRoot 'workflow-copilot.jsonl'
Write-Utf8NoBom -Path $dailyLog -Content ((@{type='assistant.message';data=@{content='Successfully reviewed ordinary error-handling code.'}}|ConvertTo-Json -Compress)+[Environment]::NewLine)
$successfulTextScan=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$successfulTextScan.status -ne 'no-incidents'){throw 'Successful assistant text produced a false-positive daily incident.'}
[IO.File]::AppendAllText($dailyLog,((@{type='session.error';data=@{message='Provider rate limit reached.'}}|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
$incidentScan=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$incidentScan.status -ne 'incidents-found' -or [int]$incidentScan.incidentCount -ne 1 -or -not(Test-Path -LiteralPath $incidentScan.reportPath)){throw 'Structured provider failure was not captured by the daily incident scan.'}

[pscustomobject]@{Passed=$true;TaskId=$taskId;DefaultAssignments=$expected;InitialProvider=[string]$copilotRoute.provider;OverrideProvider=[string]$claudeRoute.provider;ChatOnlyProviders=@('codex','copilot','claude');CleanDailyScan=[string]$daily.status;IncidentDailyScan=[string]$incidentScan.status}
