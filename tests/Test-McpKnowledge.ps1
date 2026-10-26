[CmdletBinding()]
param([string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string]$CodexHome, [string]$OutputRoot=(Join-Path ([IO.Path]::GetTempPath()) ('mcp-knowledge-'+[guid]::NewGuid().ToString('N'))))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
function Assert-That([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Write-Json($Path,$Value){[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 60)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$config.runtime.stateRoot=Join-Path $OutputRoot 'state'
$knowledgeRoot=Join-Path $OutputRoot 'global'
New-Item -ItemType Directory -Path $knowledgeRoot -Force|Out-Null
$standard=Join-Path $knowledgeRoot 'engineering-code-standards.md'
[IO.File]::WriteAllText($standard,"# Standards`nUse evidence.`nPreserve boundaries.`n")
$config.knowledge.technicalRoot=$knowledgeRoot
$config.knowledge.globalStandardsPath=$standard
$config.knowledge.versionedRoots=@($knowledgeRoot)
$config.knowledge.seedSources=@()
$projectRoot=Join-Path $OutputRoot 'project'
$otherRoot=Join-Path $OutputRoot 'other-project'
New-Item -ItemType Directory -Path $projectRoot,$otherRoot -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $projectRoot 'domain.md'),'Only the scoped project.')
[IO.File]::WriteAllText((Join-Path $otherRoot 'private.md'),'Must not be visible.')
$projects=@($config.projects|Where-Object enabled)
Assert-That ($projects.Count -ge 2) 'Fixture requires two projects.'
$projects[0].domainKnowledgeRoot=$projectRoot
foreach($project in @($projects|Select-Object -Skip 1)){$project.domainKnowledgeRoot=$otherRoot}
$repositoryId=[string]$projects[0].repositoryIds[0]
$roles=@($config.agents|ForEach-Object{[string]$_.id})
$totalCalls=0
foreach($role in $roles){
    $taskId='task-mcp-'+$role
    $taskRoot=Join-Path $OutputRoot $taskId
    New-Item -ItemType Directory -Path $taskRoot -Force|Out-Null
    $runId='run-123456789012';$leaseId='lease-123456789012';$attemptId=[guid]::NewGuid().ToString('N')
    Write-Json (Join-Path $taskRoot 'task.json') @{taskId=$taskId;status='running';practiceVersion='spec-practices-1.0.0';repositoryIds=@($repositoryId);agentStatuses=@{$role=@{status='running'}}}
    Write-Json (Join-Path $taskRoot ('execution-context-'+$runId+'.json')) @{runId=$runId;leaseId=$leaseId}
    Write-Json (Join-Path $taskRoot 'context-pack.json') @{taskId=$taskId;recipient=$role;acceptedKnowledge=@('Verified knowledge');heldScope=@('held-1');openQuestions=@();engineeringGuidance=@{selectedSkills=@('skill')};artifactSummaries=@(@{name='requirements-analysis.json';summary='Allowed'},@{name='review-verification.json';summary='Verifier only'})}
    $session=& (Join-Path $root 'scripts\New-McpSession.ps1') -TaskId $taskId -AgentId $role -RunId $runId -LeaseId $leaseId -AttemptId $attemptId -TaskRoot $taskRoot -Workspaces @($taskRoot) -Config $config
    $catalog=@($session.Session.sources)
    Assert-That (@($catalog|Where-Object path -like ($otherRoot+'*')).Count -eq 0) "Other project leaked to $role."
    Assert-That (@($catalog|Where-Object path -eq (Join-Path $projectRoot 'domain.md')).Count -eq 1) "Scoped knowledge missing for $role."
    if($role -eq 'reviewer'){Assert-That ('review-verification.json' -notin $session.Session.publicArtifacts) 'Reviewer can read the verifier artifact.'}
    $skill=@($catalog|Where-Object kind -eq 'skill')[0]
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=(Get-Command powershell.exe -ErrorAction Stop).Source
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'scripts\Start-EcosystemReadMcpServer.ps1')+'"'
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['ECOSYSTEM_MCP_SESSION_PATH']=$session.Path
    $process=[Diagnostics.Process]::Start($psi)
    function Rpc([string]$Name,$Arguments){
        $process.StandardInput.WriteLine((@{jsonrpc='2.0';id=1;method='tools/call';params=@{name=$Name;arguments=$Arguments}}|ConvertTo-Json -Depth 8 -Compress))
        $read=$process.StandardOutput.ReadLineAsync()
        if(-not $read.Wait(15000)){throw "MCP request timed out: $Name"}
        $raw=$read.Result
        if(-not $raw){throw "MCP server exited: $($process.StandardError.ReadToEnd())"}
        $response=$raw|ConvertFrom-Json
        if($response.PSObject.Properties['error']){return $response}
        $response.result.content[0].text|ConvertFrom-Json
    }
    try{
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":100,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-knowledge-test","version":"1"}}}')
        $initialize=$process.StandardOutput.ReadLine()|ConvertFrom-Json
        Assert-That ($initialize.id -eq 100 -and $initialize.result.serverInfo.name -eq 'ecosystem-read') 'MCP initialization failed.'
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","id":101,"method":"tools/list"}')
        $tools=$process.StandardOutput.ReadLine()|ConvertFrom-Json
        Assert-That ($tools.id -eq 101 -and 'read_skill' -in @($tools.result.tools.name)) 'MCP notification handling or tool discovery failed.'
        $pack=Rpc 'get_context_pack' @{}
        Assert-That ($pack.data.heldScope -contains 'held-1') "Held scope missing for $role."
        if($role -eq 'reviewer'){Assert-That (@($pack.data.artifactSummaries|Where-Object name -eq 'review-verification.json').Count -eq 0) 'Context summary leaked verifier evidence to reviewer.'}
        $state=Rpc 'get_task_state' @{}
        Assert-That ($state.data.practiceVersion -eq 'spec-practices-1.0.0') 'Task practice policy missing.'
        $knowledge=Rpc 'list_knowledge' @{limit=1}
        Assert-That ($knowledge.data.items.Count -eq 1 -and $knowledge.data.nextOffset -eq 1 -and $knowledge.truncated) 'Knowledge catalog pagination failed.'
        $entry=Rpc 'read_knowledge' @{name='global/engineering-code-standards.md';maxLines=1}
        Assert-That ($entry.data.text -eq '# Standards' -and $entry.data.nextLine -eq 2 -and $entry.truncated -and $entry.revision) 'Knowledge read lost content, revision or pagination.'
        $entry2=Rpc 'read_knowledge' @{name='global/engineering-code-standards.md';startLine=2;maxLines=2}
        Assert-That ($entry2.data.text -match 'Use evidence' -and $entry2.data.text -notmatch '# Standards') 'Knowledge continuation returned the wrong lines.'
        $skills=Rpc 'list_skills' @{}
        Assert-That ($skills.data.items.Count -gt 0) "No skills supplied to $role."
        $readSkill=Rpc 'read_skill' @{name=$skill.id;maxLines=3}
        Assert-That ($readSkill.data.text -match '---|#' -and $readSkill.revision) "Skill content missing for $role."
        $escape=Rpc 'read_knowledge' @{name='../other-project/private.md'}
        Assert-That ($escape.error.message -match 'not allowed') 'Arbitrary knowledge path was accepted.'
        $badRange=Rpc 'read_skill' @{name=$skill.id;startLine=0}
        Assert-That ($badRange.error.message -match 'out of bounds') 'Invalid line range was accepted.'
        [IO.File]::AppendAllText($standard,'Changed revision.')
        $changed=Rpc 'read_knowledge' @{name='global/engineering-code-standards.md'}
        Assert-That ($changed.error.message -match 'revision changed') 'Changed knowledge was served under an old revision.'
        [IO.File]::WriteAllText($standard,"# Standards`nUse evidence.`nPreserve boundaries.`n")
    }finally{
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(3000)){$process.Kill();$process.WaitForExit()}
        $process.Dispose()
    }
    $metrics=@(Get-Content -LiteralPath (Join-Path $taskRoot 'mcp-metrics.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert-That (@($metrics|Where-Object status -eq 'succeeded').Count -eq 7 -and @($metrics|Where-Object status -eq 'failed').Count -eq 3) "Real MCP call accounting failed for $role."
    $knowledgeMetrics=@(Get-Content -LiteralPath (Join-Path $taskRoot 'knowledge-usage.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert-That ($knowledgeMetrics.Count -eq 3 -and @($knowledgeMetrics|Where-Object{[string]$_.accessMode -ne 'read' -or -not $_.sourceRevision}).Count -eq 0) 'Actual MCP knowledge and skill reads were not recorded with source revisions.'
    $summary=& (Join-Path $root 'scripts\Get-McpTranscriptSummary.ps1') -Path (Join-Path $taskRoot 'workflow-claude.jsonl') -AttemptId $attemptId
    Assert-That ($summary.CallCount -eq 10 -and $summary.SucceededCallCount -eq 7 -and @($summary.TransportFailedServers).Count -eq 0) 'Provider-independent accounting failed or a bounded source rejection incorrectly tripped server recovery.'
    $clientLog=Join-Path $taskRoot 'workflow-codex.jsonl'
    $clientEntries=@(@{type='ecosystem-workflow-run';attemptId=$attemptId})
    for($failure=0;$failure -lt 4;$failure++){$clientEntries+=@{type='item.completed';item=@{type='mcp_tool_call';server='ecosystem-read';status='failed'}}}
    [IO.File]::WriteAllLines($clientLog,@($clientEntries|ForEach-Object{$_|ConvertTo-Json -Depth 5 -Compress}))
    $clientSummary=& (Join-Path $root 'scripts\Get-McpTranscriptSummary.ps1') -Path $clientLog -AttemptId $attemptId
    Assert-That ('ecosystem-read' -in @($clientSummary.TransportFailedServers) -and $clientSummary.CallCount -eq 11) 'A client-side transport failure was hidden by earlier server metrics.'
    $roleMetric=& (Join-Path $root 'scripts\Write-RoleAttemptMetric.ps1') -TaskRoot $taskRoot -TaskId $taskId -AgentId $role -RunId $runId -LeaseId $leaseId -AttemptId $attemptId -ConfiguredMode mcp -EffectiveMode mcp-with-tool-fallback -Status succeeded -DurationMs 10 -McpCallCount 10 -McpSucceededCallCount 7 -FallbackUsed -FallbackReasons @('read_knowledge: source revision changed')
    Assert-That ($roleMetric.Record.fallbackUsed -and $roleMetric.Record.fallbackReasons.Count -eq 1 -and $roleMetric.Record.server -eq 'ecosystem-read') 'Fallback reason or MCP server attribution was lost from role metrics.'
    $totalCalls+=$metrics.Count
}
[pscustomobject]@{Passed=$true;Roles=$roles.Count;ObservedMcpCalls=$totalCalls;OutputRoot=[IO.Path]::GetFullPath($OutputRoot)}
