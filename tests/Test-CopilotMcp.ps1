[CmdletBinding()]
param([switch]$Live,[string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/copilot-mcp'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig
$fixture=Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
$taskRoot=Join-Path $fixture 'task'
$source=Join-Path $fixture 'source'
foreach($path in @($taskRoot,(Join-Path $source 'global'),(Join-Path $source 'projects/probe'))){$null=New-Item -ItemType Directory -Path $path -Force}
$marker='MCP_'+[guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText((Join-Path $source 'global/probe.md'),$marker)
$snapshot=& (Join-Path $root 'scripts/New-SharedKnowledgeSnapshot.ps1') -SourceRoot $source -ProjectId probe -OutputRoot (Join-Path $taskRoot 'shared-knowledge')
$runId='run-probe-123456';$leaseId='lease-probe-123456';$attemptId='attempt-probe-123456'
[IO.File]::WriteAllText((Join-Path $taskRoot 'task.json'),(@{taskId='mcp-probe';status='running';agentStatuses=@{knowledge_keeper=@{status='running'}}}|ConvertTo-Json -Depth 5))
[IO.File]::WriteAllText((Join-Path $taskRoot "execution-context-$runId.json"),(@{runId=$runId;leaseId=$leaseId}|ConvertTo-Json))
$session=& (Join-Path $root 'scripts/New-McpSession.ps1') -TaskId mcp-probe -AgentId knowledge_keeper -RunId $runId -LeaseId $leaseId -TaskRoot $taskRoot -Workspaces @($taskRoot) -Config $config -AllowedTools @('get_task_state','list_knowledge','read_knowledge') -AttemptId $attemptId -KnowledgeManifestPath $snapshot.ManifestPath
function Invoke-ProbeRpc($Requests) {
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command powershell.exe).Source
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($arg in @('-NoProfile','-File',(Join-Path $root 'scripts/Start-EcosystemReadMcpServer.ps1'))){$start.ArgumentList.Add($arg)}
    $start.Environment['ECOSYSTEM_MCP_SESSION_PATH']=$session.Path
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try{
        $results=@()
        foreach($request in $Requests){
            $process.StandardInput.WriteLine(($request|ConvertTo-Json -Depth 8 -Compress))
            $line=$process.StandardOutput.ReadLineAsync()
            if(-not $line.Wait(10000)){throw 'MCP response timed out'}
            $raw=$line.Result
            if(-not $raw){throw 'MCP server closed without response'}
            $results+=($raw|ConvertFrom-Json)
        }
        return $results
    }finally{if(-not $process.HasExited){$process.Kill($true)};$process.Dispose()}
}
$results=Invoke-ProbeRpc @(
    @{jsonrpc='2.0';id=1;method='tools/call';params=@{name='list_knowledge';arguments=@{}}},
    @{jsonrpc='2.0';id=2;method='tools/call';params=@{name='read_knowledge';arguments=@{name='global/probe.md'}}},
    @{jsonrpc='2.0';id=3;method='tools/call';params=@{name='read_knowledge';arguments=@{name='../source/global/probe.md'}}}
)
if(($results[1].result.content[0].text|ConvertFrom-Json).data.excerpt -ne $marker){throw 'Knowledge MCP read did not return the bound evidence'}
if(-not $results[2].PSObject.Properties['error']){throw 'Path traversal was accepted'}
$metricsLog=Join-Path $fixture 'transcript.jsonl'
$events=@(
 @{type='ecosystem-workflow-run';attemptId='old-attempt'},
 @{type='tool.execution_start';data=@{toolCallId='old';mcpServerName='ecosystem-read'}},
 @{type='ecosystem-workflow-run';attemptId=$attemptId},
 @{type='tool.execution_complete';data=@{toolCallId='old';success=$false}},
 @{type='tool.execution_start';data=@{toolCallId='current';mcpServerName='ecosystem-read'}},
 @{type='tool.execution_complete';data=@{toolCallId='current';success=$false}}
)
[IO.File]::WriteAllLines($metricsLog,@($events|ForEach-Object{$_|ConvertTo-Json -Depth 6 -Compress}))
$metrics=& (Join-Path $root 'scripts/Get-McpTranscriptSummary.ps1') -Path $metricsLog -AttemptId $attemptId
if($metrics.CallCount -ne 1 -or $metrics.FailedCallCount -ne 1 -or $metrics.FailedServers -notcontains 'ecosystem-read'){throw 'Copilot MCP failure/attempt metrics are incorrect'}
$liveResult=$null
if($Live){
    $log=Join-Path $taskRoot 'copilot.jsonl'
    $result=& (Join-Path $root 'scripts/Invoke-CopilotRole.ps1') -Prompt 'Use ecosystem-read-list_knowledge, then ecosystem-read-read_knowledge to read global/probe.md. Do not use file tools to read the knowledge. Reply with exactly the full excerpt returned by the MCP tool.' -WorkingDirectory $taskRoot -LogPath $log -FinalResponsePath (Join-Path $taskRoot 'response.txt') -GuardArtifactPath (Join-Path $taskRoot 'guard.json') -McpSessionPath $session.Path -ReadOnly -MaxRunMinutes 2
    if($result.exitCode -ne 0 -or $result.guardTriggered){throw 'Live Copilot MCP call failed; inspect the fixture log'}
    if((Get-Content (Join-Path $taskRoot 'response.txt') -Raw).Trim() -ne $marker){throw 'Live Copilot did not return the MCP-only marker'}
    $liveResult='passed'
}
[IO.File]::WriteAllText((Join-Path $snapshot.GlobalRoot 'probe.md'),'tampered')
$failed=Invoke-ProbeRpc @(@{jsonrpc='2.0';id=4;method='tools/call';params=@{name='read_knowledge';arguments=@{name='global/probe.md'}}})
if(-not $failed[0].PSObject.Properties['error']){throw 'Changed snapshot evidence was accepted'}
[pscustomobject]@{Passed=$true;LiveCopilot=$liveResult;Fixture=$fixture;Checks=@('knowledge-list-read','path-isolation','tamper-detection')}
