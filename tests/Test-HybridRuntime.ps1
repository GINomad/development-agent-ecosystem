[CmdletBinding()]
param([string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/hybrid-runtime'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/HybridRuntime.psm1') -Force
foreach($noise in @('', 'null', '{}', '{"data":null}', '{"type":"assistant.message","data":null}', 'not json')) {
    if ($null -ne (Get-CopilotEventSummary -Line $noise)) { throw 'Non-event output was interpreted as an event.' }
}
$config=Get-Content (Join-Path $root 'config/agents.json') -Raw|ConvertFrom-Json
foreach($role in @('requirements_analyst','reviewer','review_verifier','health_check','pipeline_monitor')){
    if((Get-AgentRuntimeRoute -Config $config -AgentId $role).Provider -ne 'codex'){throw "Control role provider changed: $role"}
}
foreach($role in @('orchestrator','developer','knowledge_keeper')){
    if((Get-AgentRuntimeRoute -Config $config -AgentId $role).Provider -ne 'copilot'){throw "Copilot role provider changed: $role"}
}
$config.runtime.hybrid.providers.reviewer='copilot'
$rejected=$false
try{$null=Get-AgentRuntimeRoute -Config $config -AgentId reviewer}catch{$rejected=$_.Exception.Message -match 'must remain on Codex'}
if(-not $rejected){throw 'Reviewer independence was not enforced.'}
$config.runtime.hybrid.providers.reviewer='codex'
$config.runtime.hybrid.enabled=$false
if((Get-AgentRuntimeRoute -Config $config -AgentId developer).Provider -ne 'codex'){throw 'Classic fallback routing changed.'}
$config.runtime.PSObject.Properties.Remove('hybrid')
if((Get-AgentRuntimeRoute -Config $config -AgentId developer).Provider -ne 'codex'){throw 'Legacy configuration compatibility failed.'}
$null=New-Item -ItemType Directory -Path $OutputRoot -Force
$work=Join-Path $OutputRoot 'workspace with spaces'
$null=New-Item -ItemType Directory -Path $work -Force
$pwsh=(Get-Process -Id $PID).Path
$mock=Join-Path $PSScriptRoot 'fixtures/Mock-CopilotCli.ps1'
$runner=Join-Path $root 'scripts/Invoke-CopilotRole.ps1'
foreach($scenario in @('success','auth','silent','repeated')){
    $run=Join-Path $OutputRoot $scenario
    $null=New-Item -ItemType Directory -Path $run -Force
    $parameters=@{
        CliPath=$pwsh; CliPrefixArguments=@('-NoLogo','-NoProfile','-File',$mock,'-Scenario',$scenario)
        WorkingDirectory=$work; Prompt=('MOCK_CONTRACT '+('long prompt ''quoted'' ' * 2200))
        LogPath=(Join-Path $run 'events.jsonl');FinalResponsePath=(Join-Path $run 'response.md')
        GuardArtifactPath=(Join-Path $run 'guard.json');MaxRunMinutes=1;PollMilliseconds=100;ReadOnly=$true
    }
    $result=& $runner @parameters
    if($scenario -eq 'success'){
        if($result.exitCode -ne 0 -or $result.guardTriggered -or (Get-Content $parameters.FinalResponsePath -Raw) -ne 'MOCK_OK'){throw 'Successful runtime result was not captured.'}
        $arguments=@(Get-Content (Join-Path $work 'mock-arguments.json') -Raw|ConvertFrom-Json)
        if($arguments -notcontains '--available-tools=view,grep,glob' -or $arguments -contains '--allow-tool=shell' -or $arguments -contains '--allow-tool=write'){throw 'Read-only draft gained mutation tools.'}
        if($arguments -contains '--allow-all' -or $arguments -contains '--allow-all-paths'){throw 'Unbounded CLI permissions were enabled.'}
        $promptIndex=[array]::IndexOf($arguments,'-p')
        if($arguments[$promptIndex+1].Length -gt 2000){throw 'Expanded prompt leaked onto the command line.'}
    }
    if($scenario -eq 'auth' -and ($result.exitCode -eq 0 -or $result.failureKind -ne 'authentication')){throw 'Authentication failure was not classified.'}
    if($scenario -eq 'silent' -and -not $result.guardTriggered){throw 'Empty exit-zero was treated as success.'}
    if($scenario -eq 'repeated' -and -not $result.guardTriggered){throw 'Repeated failures did not trigger guard.'}
    if(@(Get-ChildItem (Join-Path $run 'copilot-attempts') -Recurse -Filter prompt.md).Count){throw 'Expanded prompt was retained.'}
}
$workflow=Get-Content (Join-Path $root 'scripts/Start-DevelopmentWorkflow.ps1') -Raw
foreach($required in @('Assert-TargetAgentTerminalState.ps1','Test-AgentOutcomeArtifact.ps1','Publish-AgentOutcome.ps1','Invoke-CopilotRole.ps1','requirements-draft-','Open-AgentQuestion.ps1')){
    if(-not $workflow.Contains($required)){throw "Missing workflow boundary: $required"}
}
$draftRoute=Get-AgentRuntimeRoute -Config (Get-Content (Join-Path $root 'config/agents.json') -Raw|ConvertFrom-Json) -AgentId requirements_analyst
if(-not $draftRoute.RequirementsDraft){throw 'Copilot draft stage was not enabled.'}
[pscustomobject]@{Status='passed';Providers=8;RuntimeCases=4;LargePrompt=$true;LiveCopilot='separate connection probe required'}

