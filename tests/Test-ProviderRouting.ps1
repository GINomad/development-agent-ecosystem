[CmdletBinding()]
param(
    [string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\provider-routing'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$OutputRoot=Join-Path $OutputRoot ('run-'+[guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$testConfigPath=Join-Path $OutputRoot 'agents.json'
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json
$config.runtime.stateRoot=Join-Path $OutputRoot 'state'
$hostCli=(Get-Command powershell.exe -ErrorAction Stop).Source
$config.providerRouting.providers.copilot.command=$hostCli
$config.providerRouting.providers.claude.command=$hostCli
Write-Utf8NoBom -Path $testConfigPath -Content (($config|ConvertTo-Json -Depth 100)+[Environment]::NewLine)

$expected=[ordered]@{orchestrator='claude';knowledge_keeper='claude';requirements_analyst='claude';developer='claude';reviewer='claude';review_verifier='claude';pipeline_monitor='claude';health_check='codex'}
$canonicalConfigPath=[IO.Path]::GetFullPath((Join-Path $root 'config\agents.json'))
if([IO.Path]::GetFullPath($ConfigPath) -eq $canonicalConfigPath){
    foreach($entry in $expected.GetEnumerator()){
        $agent=@($config.agents|Where-Object{[string]$_.id -eq $entry.Key}|Select-Object -First 1)
        if(-not $agent -or [string]$agent.provider -ne [string]$entry.Value){throw "Default provider assignment is incorrect for '$($entry.Key)'."}
    }
}else{
    foreach($agent in @($config.agents)){
        if([string]$agent.provider -notin @('codex','copilot','claude')){throw "Configured provider is invalid for '$($agent.id)'."}
        $expected[[string]$agent.id]=[string]$agent.provider
    }
}

$taskId='provider-route-'+[guid]::NewGuid().ToString('N')
& (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskId -TaskSelector 'Synthetic provider routing test.' -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $testConfigPath|Out-Null
$taskRoot=Join-Path $config.runtime.stateRoot ('tasks\'+$taskId)
$developerProvider=[string]$expected.developer
$developerTier=$config.providerRouting.providers.$developerProvider.models.standard
$developerRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId developer -Tier standard -ConfigPath $testConfigPath
if([string]$developerRoute.provider -ne $developerProvider -or [string]$developerRoute.model -ne [string]$developerTier.model -or [string]$developerRoute.reasoningEffort -ne [string]$developerTier.reasoningEffort){throw 'Developer provider tier mapping failed.'}
$reviewerRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId reviewer -Tier complex -ConfigPath $testConfigPath
$reviewerProvider=[string]$expected.reviewer
$reviewerTier=$config.providerRouting.providers.$reviewerProvider.models.complex
if([string]$reviewerRoute.provider -ne $reviewerProvider -or [string]$reviewerRoute.model -ne [string]$reviewerTier.model -or [string]$reviewerRoute.reasoningEffort -ne [string]$reviewerTier.reasoningEffort){throw 'Reviewer provider tier mapping failed.'}
& (Join-Path $root 'scripts\Switch-TaskAgentProvider.ps1') -TaskId $taskId -AgentId developer -Provider copilot -ConfigPath $testConfigPath|Out-Null
$overrideRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId developer -Tier standard -ConfigPath $testConfigPath
if([string]$overrideRoute.provider -ne 'copilot' -or [string]$overrideRoute.model -ne 'gpt-4.1' -or [string]$overrideRoute.reasoningEffort -ne 'medium'){throw 'Task-scoped Copilot override or tier mapping failed.'}
$taskView=& (Join-Path $root 'scripts\Get-AgentTasks.ps1') -TaskId $taskId -IncludeCompleted -ConfigPath $testConfigPath
if([string]$taskView.Tasks[0].AgentStatuses.developer.provider -ne 'copilot'){throw 'Task view did not expose the effective provider override.'}
$routingArtifact=Get-Content -LiteralPath (Join-Path $config.runtime.stateRoot "tasks\$taskId\provider-routing.json") -Raw -Encoding UTF8|ConvertFrom-Json
if(@($routingArtifact.decisions).Count -ne 3){throw 'Provider routing decisions were not persisted exactly once per changed route.'}
if(-not [bool]$config.providerRouting.limitFallback.enabled -or [string]$config.providerRouting.limitFallback.provider -ne 'codex'){throw 'Codex provider-limit fallback is not enabled behind the Claude-first assignment.'}

$workflow=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw -Encoding UTF8
$copilot=Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-CopilotRole.ps1') -Raw -Encoding UTF8
$installer=Get-Content -LiteralPath (Join-Path $root 'scripts\Install-AgentEcosystem.ps1') -Raw -Encoding UTF8
$dashboard=Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
$dashboardHost=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
$healthRecovery=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentHealthRecovery.ps1') -Raw -Encoding UTF8
foreach($token in @('configured providerRouting.limitFallback','status=repaired with requiresUserInput=false','do not request a provider administrator')){if($healthRecovery -notmatch [regex]::Escape($token)){throw "Health recovery prompt is missing configured provider-limit fallback precedence: '$token'."}}
$providerLimitClassifierSource=Get-Content -LiteralPath (Join-Path $root 'scripts\Test-ProviderLimitDiagnostic.ps1') -Raw -Encoding UTF8
foreach($token in @('Get-CodexMcpOverrides.ps1','additional-mcp-config','--mcp-config','--enable-mcp-server=','mcp get','McpServers','provider-limit-','AutomaticLimitFallback','provider_limit_fallback','individual spend limit','spend(?:ing)? limit')){if(($workflow+$copilot+$providerLimitClassifierSource) -notmatch [regex]::Escape($token)){throw "Provider runtime is missing '$token'."}}
foreach($token in @('$codexSelected','if($codexSelected)','-not $SkipPlugin -and $codexSelected')){if($installer -notmatch [regex]::Escape($token)){throw "Installer does not support a no-Codex role selection ('$token')."}}
foreach($token in @('agentProviderSelect','switchAgentProvider','Switch-TaskAgentProvider.ps1','/provider')){if(($dashboard+$dashboardHost) -notmatch [regex]::Escape($token)){throw "Dashboard provider switching is missing '$token'."}}

$providerLimitClassifier=Join-Path $root 'scripts\Test-ProviderLimitDiagnostic.ps1'
foreach($token in @('Test-ProviderLimitDiagnostic.ps1','individual spend limit','execution retry limit reached')){if(($workflow+$providerLimitClassifierSource) -notmatch [regex]::Escape($token)){throw "Provider-limit classifier integration is missing '$token'."}}
if([bool](& $providerLimitClassifier -Diagnostic 'Execution retry limit reached after 3 identical failures: Get-Help -Full -LiteralPath is invalid.')){throw 'Execution retry exhaustion was misclassified as a provider capacity limit.'}
if(-not [bool](& $providerLimitClassifier -Diagnostic 'Provider rate limit reached.')){throw 'Provider rate-limit diagnostic was not classified for configured fallback.'}
if(-not [bool](& $providerLimitClassifier -Diagnostic 'Individual spend limit reached.')){throw 'Provider spend-limit diagnostic was not classified for configured fallback.'}
$emptyMcpSession=& (Join-Path $root 'scripts\New-McpSession.ps1') -TaskId $taskId -AgentId reviewer -RunId 'run-provider-test' -LeaseId 'lease-provider-test' -TaskRoot $taskRoot -Workspaces @($root) -AllowedTools @() -Config $config -AttemptId 'attempt-provider-test'
if(@($emptyMcpSession.Session.allowedTools).Count){throw 'An external-only MCP policy was repopulated with local ecosystem-read tools.'}

foreach($provider in @('codex','copilot','claude')){
    $installParameters=@{Provider=$provider;DestinationRoot=(Join-Path $OutputRoot ('preview-'+$provider));ConfigPath=$testConfigPath}
    if($provider -ne 'codex'){$installParameters.Preview=$true}
    $preview=& (Join-Path $root 'scripts\Install-ChatOnlyAgents.ps1') @installParameters
    $managedAssetCount=@($preview.Written).Count+@($preview.Unchanged).Count
    if($managedAssetCount -ne 13 -or [bool]$preview.DashboardInstalled){throw "Chat-only preview for '$provider' is incomplete."}
    if($provider -eq 'codex'){
        $codexAgent=Get-Content -LiteralPath (Join-Path $preview.DestinationRoot 'agents\development_implementer.toml') -Raw -Encoding UTF8
        if($codexAgent -notmatch 'standalone Codex agent-only mode' -or $codexAgent -match 'standalone GitHub Copilot'){throw 'Codex chat-only agent still depends on another provider profile.'}
    }
}
$daily=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$daily.status -ne 'no-incidents' -or $daily.reportPath){throw 'A clean daily health scan was not a true no-op.'}
$dailyLog=Join-Path $taskRoot 'workflow-copilot.jsonl'
Write-Utf8NoBom -Path $dailyLog -Content ((@{type='assistant.message';data=@{content='Successfully reviewed ordinary error-handling code.'}}|ConvertTo-Json -Compress)+[Environment]::NewLine)
$successfulTextScan=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$successfulTextScan.status -ne 'no-incidents'){throw 'Successful assistant text produced a false-positive daily incident.'}
[IO.File]::AppendAllText($dailyLog,((@{type='session.error';data=@{message='Provider rate limit reached. Authorization: Bearer bearer-secret-value';context=@{apiKey='nested-secret-value';password='nested-password-value'}}}|ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
$incidentScan=& (Join-Path $root 'scripts\Invoke-DailyHealthIncidentScan.ps1') -ConfigPath $testConfigPath
if([string]$incidentScan.status -ne 'incidents-found' -or [int]$incidentScan.incidentCount -ne 1 -or -not(Test-Path -LiteralPath $incidentScan.reportPath)){throw 'Structured provider failure was not captured by the daily incident scan.'}
$incidentReport=Get-Content -LiteralPath $incidentScan.reportPath -Raw -Encoding UTF8
foreach($secret in @('bearer-secret-value','nested-secret-value','nested-password-value')){if($incidentReport -match [regex]::Escape($secret)){throw "Daily incident report leaked '$secret'."}}
if($incidentReport -notmatch '\[redacted\]' -or $incidentReport -notmatch '"signature"\s*:\s*"[a-f0-9]{64}"'){throw 'Daily incident report lacks redacted, fingerprinted evidence.'}
if($incidentReport -match '"path"\s*:' -or $incidentReport -match [regex]::Escape([IO.Path]::GetFullPath($OutputRoot))){throw 'Daily incident report persisted an absolute local path.'}

$providerLimitPath=Join-Path $taskRoot 'provider-limit-developer.json'
Write-Utf8NoBom -Path $providerLimitPath -Content (([ordered]@{schemaVersion=2;taskId=$taskId;agentId='developer';provider='claude';category='usage-limit';fallbackProvider='codex';automaticFallback=$true}|ConvertTo-Json)+[Environment]::NewLine)
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $taskId -AgentId developer -AgentStatus running -Stage provider_test -ConfigPath $testConfigPath|Out-Null
$fallbackSwitch=& (Join-Path $root 'scripts\Switch-TaskAgentProvider.ps1') -TaskId $taskId -AgentId developer -Provider codex -AutomaticLimitFallback -ConfigPath $testConfigPath
if(-not [bool]$fallbackSwitch.automaticLimitFallback -or [string]$fallbackSwitch.provider -ne 'codex'){throw 'Automatic provider-limit fallback did not switch the active role to Codex.'}
if(-not(Test-Path -LiteralPath $providerLimitPath -PathType Leaf)){throw 'Automatic provider-limit fallback removed its diagnostic artifact.'}
$fallbackRoute=& (Join-Path $root 'scripts\Resolve-AgentProviderRoute.ps1') -TaskId $taskId -AgentId developer -Tier standard -ConfigPath $testConfigPath
if([string]$fallbackRoute.provider -ne 'codex'){throw 'Provider routing did not honor the automatic Codex fallback override.'}

[pscustomobject]@{Passed=$true;TaskId=$taskId;DefaultAssignments=$expected;InitialProvider=[string]$developerRoute.provider;OverrideProvider=[string]$overrideRoute.provider;ChatOnlyProviders=@('codex','copilot','claude');CleanDailyScan=[string]$daily.status;IncidentDailyScan=[string]$incidentScan.status}
