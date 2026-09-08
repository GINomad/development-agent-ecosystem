[CmdletBinding()]
param([string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string] $CodexHome)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
function Assert-That { param([bool]$Condition,[string]$Message); if(-not $Condition){throw $Message} }
$workflowSource=Get-Content -LiteralPath (Join-Path $root 'scripts\Start-DevelopmentWorkflow.ps1') -Raw
Assert-That ($workflowSource -match 'Expand-EcosystemValue -Value \$value.+-StateRoot \$mcpStateRoot') 'Workflow does not expand MCP command arguments before passing them to Codex.'
Assert-That ($workflowSource -notmatch '@\(\$mcpServer\.arguments \| ForEach-Object \{ \[string\]\$_ \}\) \| ConvertTo-Json') 'Workflow still passes unresolved MCP command arguments to Codex.'
Assert-That ($workflowSource -notmatch 'if\s*\(@\(\$enabledMcpServerNames\)\.Count\)') 'Classic workflow still skips global MCP disable overrides when its enabled-server list is empty.'
foreach($case in @(@{status='completed';success=$true},@{status='waiting';success=$false},@{status='failed';success=$false},@{status='skipped';success=$false})){$outcome=& (Join-Path $root 'scripts\Resolve-McpTerminalOutcome.ps1') -AgentStatus $case.status;Assert-That ([bool]$outcome.Succeeded -eq [bool]$case.success) "Terminal outcome '$($case.status)' has incorrect canary result.";Assert-That ([int]$outcome.QualityProxy -eq $(if($case.success){1}else{0})) "Terminal outcome '$($case.status)' has incorrect quality proxy."}
function New-RpcFixture {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('ecosystem-mcp-test-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $fixture -Force|Out-Null
    $taskId='rpc-task';$runId='run-123456789012';$leaseId='lease-123456789012'
    [IO.File]::WriteAllText((Join-Path $fixture 'task.json'),((@{taskId=$taskId;id=$taskId;status='running';currentStage='requirements_analyst';agentStatuses=@{requirements_analyst=@{status='running'}}}|ConvertTo-Json -Depth 8)+[Environment]::NewLine))
    [IO.File]::WriteAllText((Join-Path $fixture ('execution-context-'+$runId+'.json')),((@{runId=$runId;leaseId=$leaseId}|ConvertTo-Json)+[Environment]::NewLine))
    [pscustomobject]@{Root=$fixture;TaskId=$taskId;RunId=$runId;LeaseId=$leaseId;SessionPath=(Join-Path $fixture 'session.json')}
}
function Write-RpcSession { param($Fixture,[string[]]$AllowedTools=@('get_task_state'),[string[]]$PublicArtifacts=@())
    $config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
    $created=& (Join-Path $root 'scripts\New-McpSession.ps1') -TaskId $Fixture.TaskId -AgentId requirements_analyst -RunId $Fixture.RunId -LeaseId $Fixture.LeaseId -TaskRoot $Fixture.Root -Workspaces @($Fixture.Root) -Config $config -AllowedTools $AllowedTools
    $Fixture.SessionPath=[string]$created.Path
    return $created.Session
}
function Invoke-RpcServer {
    param([string]$SessionPath,[object[]]$Requests=@(),[switch]$WaitForExit)
    $serverPath=Join-Path $root 'scripts\Start-EcosystemReadMcpServer.ps1'
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Get-Command powershell.exe -ErrorAction Stop).Source
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$serverPath+'"';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.EnvironmentVariables['ECOSYSTEM_MCP_SESSION_PATH']=$SessionPath
    $process=[Diagnostics.Process]::Start($psi);$responses=[Collections.Generic.List[object]]::new()
    try {
        if($WaitForExit){Assert-That ($process.WaitForExit(5000)) 'Invalid MCP session process did not terminate.';return [pscustomobject]@{ExitCode=$process.ExitCode;Responses=@($responses);Error=$process.StandardError.ReadToEnd()}}
        foreach($request in $Requests){$process.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 12 -Compress));$raw=$process.StandardOutput.ReadLine();if([string]::IsNullOrWhiteSpace($raw)){if($process.WaitForExit(1000)){$detail=$process.StandardError.ReadToEnd()}else{$detail='process remained running'};throw "MCP server returned no JSON-RPC response: $detail"};$responses.Add(($raw|ConvertFrom-Json))}
        [pscustomobject]@{ExitCode=$null;Responses=@($responses);Error=$null}
    } finally { try{$process.StandardInput.Close()}catch{};if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose() }
}

$fixture=New-RpcFixture
try {
    # Startup rejects a modified hash and every persisted session binding independently.
    $session=Write-RpcSession $fixture;$sessionConfig=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome;Assert-That ([int]$session.toolTimeoutSeconds -eq [int]$sessionConfig.mcp.resilience.toolTimeoutSeconds) 'Signed MCP session does not carry the configured client tool timeout.';$session.taskId='tampered-task';[IO.File]::WriteAllText($fixture.SessionPath,(($session|ConvertTo-Json -Depth 8)+[Environment]::NewLine));$result=Invoke-RpcServer -SessionPath $fixture.SessionPath -WaitForExit;Assert-That ($result.ExitCode -ne 0 -and $result.Error -match 'integrity') ("Tampered HMAC-signed session field was accepted. exit={0}; error={1}" -f $result.ExitCode,$result.Error)
    $null=Write-RpcSession $fixture;[IO.File]::WriteAllText((Join-Path $fixture.Root 'task.json'),((@{taskId='other-task';id='other-task';status='running';agentStatuses=@{requirements_analyst=@{status='running'}}}|ConvertTo-Json -Depth 8)+[Environment]::NewLine));$result=Invoke-RpcServer -SessionPath $fixture.SessionPath -WaitForExit;Assert-That ($result.ExitCode -ne 0) 'Task ID mismatch was accepted.';[IO.File]::WriteAllText((Join-Path $fixture.Root 'task.json'),((@{taskId=$fixture.TaskId;id=$fixture.TaskId;status='running';agentStatuses=@{requirements_analyst=@{status='running'}}}|ConvertTo-Json -Depth 8)+[Environment]::NewLine))
    $session=Write-RpcSession $fixture;[IO.File]::WriteAllText((Join-Path $fixture.Root ('execution-context-'+$fixture.RunId+'.json')),((@{runId='different-run';leaseId=$fixture.LeaseId}|ConvertTo-Json)+[Environment]::NewLine));$result=Invoke-RpcServer -SessionPath $fixture.SessionPath -WaitForExit;Assert-That ($result.ExitCode -ne 0) 'Run ID mismatch was accepted.'
    [IO.File]::WriteAllText((Join-Path $fixture.Root ('execution-context-'+$fixture.RunId+'.json')),((@{runId=$fixture.RunId;leaseId='different-lease'}|ConvertTo-Json)+[Environment]::NewLine));$result=Invoke-RpcServer -SessionPath $fixture.SessionPath -WaitForExit;Assert-That ($result.ExitCode -ne 0) 'Lease ID mismatch was accepted.'
    [IO.File]::WriteAllText((Join-Path $fixture.Root ('execution-context-'+$fixture.RunId+'.json')),((@{runId=$fixture.RunId;leaseId=$fixture.LeaseId}|ConvertTo-Json)+[Environment]::NewLine))
    $null=Write-RpcSession $fixture -AllowedTools get_task_state
    $happy=Invoke-RpcServer -SessionPath $fixture.SessionPath -Requests @(
        @{jsonrpc='2.0';id=10;method='initialize';params=@{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='resilience-test';version='1'}}},
        @{jsonrpc='2.0';id=11;method='tools/call';params=@{name='get_task_state';arguments=@{}}}
    )
    Assert-That ($happy.Responses.Count -eq 2 -and [int]$happy.Responses[0].id -eq 10 -and [int]$happy.Responses[1].id -eq 11) 'MCP initialize/tool responses did not preserve JSON-RPC request IDs.'
    Assert-That ([bool]$happy.Responses[1].PSObject.Properties['result']) ('MCP get_task_state happy path returned an error: '+($happy.Responses[1]|ConvertTo-Json -Depth 8 -Compress))
    Assert-That ([string]$happy.Responses[1].result.content[0].text -match '"taskId":"rpc-task"') 'MCP get_task_state happy path did not return the bound task ID.'
    $null=Write-RpcSession $fixture -AllowedTools get_artifact_summary
    $private=Invoke-RpcServer -SessionPath $fixture.SessionPath -Requests @(@{jsonrpc='2.0';id=1;method='tools/call';params=@{name='get_artifact_summary';arguments=@{name='agent-checkpoints/requirements_analyst.json'}}})
    Assert-That ($private.Responses[0].error.message -match 'not public') ("A valid session read a private artifact or returned an unexpected response: " + ($private.Responses[0]|ConvertTo-Json -Compress))
    $escape=Invoke-RpcServer -SessionPath $fixture.SessionPath -Requests @(@{jsonrpc='2.0';id=2;method='tools/call';params=@{name='get_artifact_summary';arguments=@{name='../other-task.json'}}})
    Assert-That ($escape.Responses[0].error.message -match 'not public|escapes task root') 'Cross-task path traversal was accepted.'
    $metricPath=Join-Path $fixture.Root 'mcp-metrics.jsonl';$metrics=@(Get-Content -LiteralPath $metricPath -Encoding UTF8|ForEach-Object{$_|ConvertFrom-Json});Assert-That (@($metrics|Where-Object status -eq 'failed').Count -ge 2) 'Failed MCP tool calls did not produce per-call metrics.'
} finally { if(Test-Path -LiteralPath $fixture.Root){Remove-Item -LiteralPath $fixture.Root -Recurse -Force} }

$inventoryFixture=Join-Path ([IO.Path]::GetTempPath()) ('ecosystem-mcp-inventory-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $inventoryFixture -Force|Out-Null
try {
    $fakeCodex=Join-Path $inventoryFixture 'fake-codex.ps1'
    $fakeSource=@'
param([Parameter(ValueFromRemainingArguments=$true)][object[]]$Arguments)
'[{"name":"one","transport":{"command":"one.exe","args":[]}},{"name":"two","transport":{"url":"https://example.test/mcp"}}]'
'@
    [IO.File]::WriteAllText($fakeCodex,$fakeSource)
    $global:LASTEXITCODE=0
    $classic=@(& (Join-Path $root 'scripts\Get-CodexMcpOverrides.ps1') -CodexPath $fakeCodex -EnabledServers @())
    Assert-That (@($classic|Where-Object{$_ -match '^mcp_servers\.(one|two)\.enabled=false$'}).Count -eq 2) 'Classic overrides did not disable every registered MCP server.'
    $global:LASTEXITCODE=0
    $enabled=@(& (Join-Path $root 'scripts\Get-CodexMcpOverrides.ps1') -CodexPath $fakeCodex -EnabledServers one -ServerPolicies @([pscustomobject]@{name='one';roleTools=@('read')}) -ToolTimeoutSeconds 7)
    Assert-That ('mcp_servers.one.tool_timeout_sec=7' -in $enabled) 'Enabled MCP server did not receive the configured Codex client timeout.'
} finally { if(Test-Path -LiteralPath $inventoryFixture){Remove-Item -LiteralPath $inventoryFixture -Recurse -Force} }

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ecosystem-mcp-circuit-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try {
    $testConfig=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json;$testConfig.runtime.stateRoot=Join-Path $testRoot 'state';$testConfig.mcp.defaultMode='allowlist';$testConfigPath=Join-Path $testRoot 'agents.json';[IO.File]::WriteAllText($testConfigPath,(($testConfig|ConvertTo-Json -Depth 40)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    $server='ecosystem-read';$opened=$null;for($i=1;$i -le [int]$testConfig.mcp.resilience.failureThreshold;$i++){$opened=& (Join-Path $root 'scripts\Set-McpCircuitState.ps1') -ServerName $server -State open -FailureSignature ('test-'+$i) -ConfigPath $testConfigPath -CodexHome $CodexHome};Assert-That ($opened.state -eq 'open') 'Circuit did not open after its configured threshold.'
    $resolvedTestConfig=Get-EcosystemConfig -ConfigPath $testConfigPath -CodexHome $CodexHome;$statePath=Join-Path (Get-EcosystemStateRoot -Config $resolvedTestConfig -CodexHome $CodexHome) ('health\mcp\'+$server+'.json');$state=Get-Content $statePath -Raw|ConvertFrom-Json;$state.retryAfterUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o');[IO.File]::WriteAllText($statePath,(($state|ConvertTo-Json -Depth 8)+[Environment]::NewLine))
    $firstClaim=& (Join-Path $root 'scripts\Claim-McpCanary.ps1') -ServerName $server -ClaimId one -ConfigPath $testConfigPath -CodexHome $CodexHome;Assert-That ([bool]$firstClaim) ("First canary claim was not granted: {0}" -f ((Get-Content $statePath -Raw)))
    Assert-That (-not [bool](& (Join-Path $root 'scripts\Claim-McpCanary.ps1') -ServerName $server -ClaimId two -ConfigPath $testConfigPath -CodexHome $CodexHome)) 'A second simultaneous canary claim was granted.'
    $required=[int]$testConfig.mcp.resilience.requiredSuccessfulProbes;for($i=1;$i -le $required;$i++){if($i -gt 1){$claim='claim-'+$i;Assert-That ([bool](& (Join-Path $root 'scripts\Claim-McpCanary.ps1') -ServerName $server -ClaimId $claim -ConfigPath $testConfigPath -CodexHome $CodexHome)) 'A released half-open canary claim was not granted.'}else{$claim='one'};$state=& (Join-Path $root 'scripts\Complete-McpCanary.ps1') -ServerName $server -ClaimId $claim -Succeeded $true -ConfigPath $testConfigPath -CodexHome $CodexHome;if($i -lt $required){Assert-That ($state.state -eq 'half-open' -and -not $state.canaryClaimId) 'Circuit did not release claim before all required probes.'}}
    Assert-That ($state.state -eq 'healthy') 'Circuit did not become healthy after required probes.'
    for($i=1;$i -le [int]$testConfig.mcp.resilience.failureThreshold;$i++){$opened=& (Join-Path $root 'scripts\Set-McpCircuitState.ps1') -ServerName $server -State open -FailureSignature ('again-'+$i) -ConfigPath $testConfigPath -CodexHome $CodexHome};$state=Get-Content $statePath -Raw|ConvertFrom-Json;$state.retryAfterUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o');[IO.File]::WriteAllText($statePath,(($state|ConvertTo-Json -Depth 8)+[Environment]::NewLine));$null=& (Join-Path $root 'scripts\Claim-McpCanary.ps1') -ServerName $server -ClaimId failing -ConfigPath $testConfigPath -CodexHome $CodexHome;$failed=& (Join-Path $root 'scripts\Complete-McpCanary.ps1') -ServerName $server -ClaimId failing -Succeeded $false -ConfigPath $testConfigPath -CodexHome $CodexHome;Assert-That ($failed.state -eq 'open') 'Failed half-open canary did not reopen circuit.'
    $testConfig.mcp.resilience.maxConcurrentRepairs=1;[IO.File]::WriteAllText($testConfigPath,(($testConfig|ConvertTo-Json -Depth 40)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    $recovery=& (Join-Path $root 'scripts\Start-McpHealthRecovery.ps1') -ServerName queue-server -FailureSignature same-signature -TaskId task-one -AgentId requirements_analyst -ExecutionRunId run-one -WorkspaceLeaseId lease-one -NoStartWorker -ConfigPath $testConfigPath -CodexHome $CodexHome
    $queued=& (Join-Path $root 'scripts\Start-McpHealthRecovery.ps1') -ServerName queue-server -FailureSignature same-signature -TaskId task-two -AgentId requirements_analyst -ExecutionRunId run-two -WorkspaceLeaseId lease-two -NoStartWorker -ConfigPath $testConfigPath -CodexHome $CodexHome
    $repeat=& (Join-Path $root 'scripts\Start-McpHealthRecovery.ps1') -ServerName queue-server -FailureSignature same-signature -TaskId task-two -AgentId requirements_analyst -ExecutionRunId run-two -WorkspaceLeaseId lease-two -NoStartWorker -ConfigPath $testConfigPath -CodexHome $CodexHome
    Assert-That ($recovery.IncidentPath -ne $queued.IncidentPath -and $queued.Status -eq 'queued' -and $repeat.Deduplicated -and $repeat.IncidentPath -eq $queued.IncidentPath) 'Distinct queued MCP incidents collided or repeated task/run was not deduplicated.'
    Assert-That ((Get-Content $recovery.IncidentPath -Raw|ConvertFrom-Json).status -eq 'repairing') 'First MCP incident was overwritten while queueing another task/run.'
    $metricRoot=Join-Path $testRoot 'report-metrics';New-Item -ItemType Directory -Path $metricRoot|Out-Null;$baseline=@{mode='classic';agentId='requirements_analyst';server='classic';status='succeeded';durationMs=100;qualityObserved=$true;qualityValue=1}|ConvertTo-Json -Compress;$canary=@{mode='mcp';agentId='requirements_analyst';server='ecosystem-read';status='succeeded';durationMs=90;qualityObserved=$true;qualityValue=1}|ConvertTo-Json -Compress;[IO.File]::WriteAllText((Join-Path $metricRoot 'role-metrics.jsonl'),($baseline+[Environment]::NewLine+$canary+[Environment]::NewLine));$report=& (Join-Path $root 'scripts\Get-McpMigrationReport.ps1') -MetricsRoot $metricRoot -MinimumSampleSize 1 -OutputPath (Join-Path $metricRoot 'continue.json');Assert-That ($report.Report.decision -eq 'continue') 'Comparable successful metrics did not permit migration continuation.'
    $canaryBad=@{mode='mcp';agentId='requirements_analyst';server='ecosystem-read';status='failed';durationMs=900;qualityObserved=$true;qualityValue=0}|ConvertTo-Json -Compress;[IO.File]::WriteAllText((Join-Path $metricRoot 'role-metrics.jsonl'),($baseline+[Environment]::NewLine+$canaryBad+[Environment]::NewLine));$report=& (Join-Path $root 'scripts\Get-McpMigrationReport.ps1') -MetricsRoot $metricRoot -MinimumSampleSize 1 -OutputPath (Join-Path $metricRoot 'rollback.json');Assert-That ($report.Report.decision -eq 'rollback') 'Bad canary metrics did not require rollback.'
} finally { if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force} }
Write-Output 'MCP resilience checks passed: process binding/isolation and exclusive circuit canary behavior.'
