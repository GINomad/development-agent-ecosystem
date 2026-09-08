[CmdletBinding()]
param([string] $SessionPath = $env:ECOSYSTEM_MCP_SESSION_PATH,[switch] $Probe)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
function Reply($Value) { [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 12 -Compress)); [Console]::Out.Flush() }
function FileSha([string] $Path) { $sha=[Security.Cryptography.SHA256]::Create();try{$stream=[IO.File]::OpenRead($Path);try{([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose()}}finally{$sha.Dispose()} }
if ($Probe) { Write-Output 'ecosystem-read: healthy'; exit 0 }
if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath -PathType Leaf)) { throw 'A bound immutable MCP session is required.' }
$session = Get-Content -LiteralPath $SessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($name in 'taskId','agentId','runId','leaseId','taskRoot','allowedTools','publicArtifacts','metricsPath','signingKeyPath','maxCalls','maxResponseBytes','toolTimeoutSeconds','sessionHmac') { if (-not $session.PSObject.Properties[$name]) { throw "MCP session is missing '$name'." } }
$keyPath=[IO.Path]::GetFullPath([string]$session.signingKeyPath);if($keyPath.StartsWith([IO.Path]::GetFullPath([string]$session.taskRoot),[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $keyPath)){throw 'MCP session signing key is missing or unsafe.'};$copy=[ordered]@{};foreach($property in $session.PSObject.Properties){if($property.Name -ne 'sessionHmac'){$copy[$property.Name]=$property.Value}};$hmac=[Security.Cryptography.HMACSHA256]::new([IO.File]::ReadAllBytes($keyPath));try{$expected=([BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes(($copy|ConvertTo-Json -Depth 8 -Compress))))).Replace('-','').ToLowerInvariant()}finally{$hmac.Dispose()};if($expected -ne [string]$session.sessionHmac){throw 'MCP session integrity validation failed.'}
$taskRoot = [IO.Path]::GetFullPath([string]$session.taskRoot).TrimEnd('\') + '\'
$taskDocument=Get-Content (Join-Path $taskRoot 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json;$persistedTaskId=if($taskDocument.PSObject.Properties['taskId']){[string]$taskDocument.taskId}else{[string]$taskDocument.id};if($persistedTaskId -ne [string]$session.taskId){throw 'MCP session task binding does not match task.json.'}
$agentStatus=$null;if(-not $taskDocument.PSObject.Properties['agentStatuses'] -or -not $taskDocument.agentStatuses.PSObject.Properties[[string]$session.agentId]){throw 'MCP session agent status is missing for this task.'};$agentStatus=[string]$taskDocument.agentStatuses.([string]$session.agentId).status;if($agentStatus -ne 'running'){throw 'MCP session agent is not actively running for this task.'}
$taskRun=if($taskDocument.PSObject.Properties['executionRunId']){[string]$taskDocument.executionRunId}else{''};$taskLease=if($taskDocument.PSObject.Properties['workspaceLeaseId']){[string]$taskDocument.workspaceLeaseId}else{''};if(($taskRun -and $taskRun -ne [string]$session.runId) -or ($taskLease -and $taskLease -ne [string]$session.leaseId)){throw 'MCP session does not own the active task lease.'}
$executionPath=Join-Path $taskRoot ('execution-context-'+[string]$session.runId+'.json');if(-not(Test-Path $executionPath)){throw 'MCP execution context is missing.'};$execution=Get-Content $executionPath -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$execution.runId -ne [string]$session.runId -or [string]$execution.leaseId -ne [string]$session.leaseId){throw 'MCP session run or lease binding does not match execution context.'}
function TaskPath([string] $Name) { $path = Join-Path $taskRoot $Name; if (-not $path.StartsWith($taskRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Requested path escapes task root.' }; $path }
function Envelope($Source,$Data,[bool]$Truncated=$false) { $path=TaskPath $Source; @{source=$Source;revision=if(Test-Path $path){FileSha $path}else{$null};retrievedAtUtc=[DateTime]::UtcNow.ToString('o');truncated=$Truncated;data=$Data} }
 $callCount=0
function WriteMetric($Status,$Tool,$Duration,$Bytes,$ErrorClass,[int]$RequestBytes=0,[string]$SourceRevision=$null){$circuitState='unknown';$circuitPath=Join-Path (Split-Path -Parent ([string]$session.signingKeyPath)) 'ecosystem-read.json';if(Test-Path -LiteralPath $circuitPath){try{$circuitState=[string]((Get-Content -LiteralPath $circuitPath -Raw -Encoding UTF8|ConvertFrom-Json).state)}catch{}};$record=[ordered]@{schemaVersion=1;timestampUtc=[DateTime]::UtcNow.ToString('o');taskId=$session.taskId;runId=$session.runId;leaseId=$session.leaseId;agentId=$session.agentId;server='ecosystem-read';tool=$Tool;status=$Status;durationMs=$Duration;requestBytes=$RequestBytes;responseBytes=$Bytes;cacheStatus='not-applicable';circuitState=$circuitState;sourceRevision=$SourceRevision;fallbackUsed=$false;errorClass=$ErrorClass;mode='mcp'};$path=[string]$session.metricsPath;$lock=$path+'.lock';$stream=[IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{[IO.File]::AppendAllText($path,(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}finally{$stream.Dispose()}}
function ToolResult($Name,$ToolArguments) {
 $started=[Diagnostics.Stopwatch]::StartNew();try {
 $callCount++;if($callCount -gt [int]$session.maxCalls){throw 'MCP role call limit exceeded.'}
 if ($Name -notin @($session.allowedTools)) { throw "Tool '$Name' is not allowed for this role." }
 switch($Name) {
  'get_task_state' { $path=TaskPath 'task.json'; $task=Get-Content $path -Raw -Encoding UTF8|ConvertFrom-Json; $taskId=if($task.PSObject.Properties['taskId']){[string]$task.taskId}else{[string]$task.id}; $currentStage=if($task.PSObject.Properties['currentStage']){[string]$task.currentStage}else{$null}; $data=@{taskId=$taskId;status=$task.status;currentStage=$currentStage;agentStatuses=$task.agentStatuses}; $value=Envelope 'task.json' $data }
  'get_artifact_summary' { $artifact=[string]$ToolArguments.name; if($artifact -notin @($session.publicArtifacts)){throw 'Artifact is not public for this role.'}; $path=TaskPath $artifact; $data=@{artifact=$artifact;exists=(Test-Path $path);sha256=if(Test-Path $path){FileSha $path}else{$null}}; $value=Envelope $artifact $data }
  'read_artifact_evidence' { $artifact=[string]$ToolArguments.name; if($artifact -notin @($session.publicArtifacts)){throw 'Artifact is not public for this role.'}; $path=TaskPath $artifact; $raw=Get-Content $path -Raw -Encoding UTF8; $limited=$raw.Substring(0,[Math]::Min($raw.Length,16384)); $value=Envelope $artifact @{artifact=$artifact;excerpt=$limited} ($raw.Length -gt $limited.Length) }
  'list_pending_comments' {
    $path=TaskPath 'task-ledger.jsonl'; $events=@()
    if(Test-Path $path){ $events=@(Get-Content $path -Encoding UTF8|Where-Object{$_}|ForEach-Object{try{$_|ConvertFrom-Json}catch{}}) }
    $ack=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($event in @($events|Where-Object{[string]$_.type -eq 'user-comment-acknowledged'})){ foreach($id in @($event.evidence)){ if($id){$null=$ack.Add([string]$id)} } }
    $items=@($events|Where-Object{[string]$_.type -in @('user-comment','agent-routing-request','workflow-input-routed') -and -not $ack.Contains([string]$_.eventId) -and (-not $_.PSObject.Properties['targetAgentId'] -or [string]::IsNullOrWhiteSpace([string]$_.targetAgentId) -or [string]$_.targetAgentId -eq [string]$session.agentId)}|Sort-Object timestampUtc|ForEach-Object{
      $sourceEventId=if([string]$_.type -eq 'workflow-input-routed' -and @($_.evidence).Count){[string]$_.evidence[0]}else{[string]$_.eventId}
      $target=if($_.PSObject.Properties['targetAgentId']){[string]$_.targetAgentId}else{$null}
      [pscustomobject]@{eventId=[string]$_.eventId;timestampUtc=[string]$_.timestampUtc;author=[string]$_.actor;text=[string]$_.summary;eventType=[string]$_.type;sourceEventId=$sourceEventId;targetAgentId=$target;evidence=@($_.evidence)}
    })
    $value=Envelope 'task-ledger.jsonl' $items
  }
  default { throw "Unsupported tool '$Name'." }
 }
 $text=$value|ConvertTo-Json -Depth 12 -Compress;if([Text.Encoding]::UTF8.GetByteCount($text) -gt [int]$session.maxResponseBytes){throw 'MCP response exceeds configured limit.'};WriteMetric 'succeeded' $Name $started.ElapsedMilliseconds ([Text.Encoding]::UTF8.GetByteCount($text)) $null $script:requestBytes ([string]$value.revision);@{content=@(@{type='text';text=$text});isError=$false}
 } catch {WriteMetric 'failed' $Name $started.ElapsedMilliseconds 0 'tool-error' $script:requestBytes;throw}
}
$tools=@(); foreach($tool in @($session.allowedTools)){ $tools += @{name=$tool;description='Task-scoped read-only ecosystem data.';inputSchema=@{type='object';properties=@{name=@{type='string'}};additionalProperties=$false}} }
$script:requestBytes=0
while(($line=[Console]::In.ReadLine()) -ne $null){$id=$null;try{$script:requestBytes=[Text.Encoding]::UTF8.GetByteCount($line);$request=$line|ConvertFrom-Json;$id=$request.id;switch([string]$request.method){'initialize'{Reply @{jsonrpc='2.0';id=$id;result=@{protocolVersion='2024-11-05';capabilities=@{tools=@{}};serverInfo=@{name='ecosystem-read';version='1.1.0'}}}}'notifications/initialized'{}'tools/list'{Reply @{jsonrpc='2.0';id=$id;result=@{tools=$tools}}}'tools/call'{Reply @{jsonrpc='2.0';id=$id;result=(ToolResult $request.params.name $request.params.arguments)}}default{Reply @{jsonrpc='2.0';id=$id;error=@{code=-32601;message='Method not found'}}}}}catch{Reply @{jsonrpc='2.0';id=$id;error=@{code=-32603;message=$_.Exception.Message}}}}
