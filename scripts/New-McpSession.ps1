[CmdletBinding()]
param([Parameter(Mandatory)][string] $TaskId,[Parameter(Mandatory)][string] $AgentId,[Parameter(Mandatory)][string] $RunId,[Parameter(Mandatory)][string] $LeaseId,[Parameter(Mandatory)][string] $TaskRoot,[Parameter(Mandatory)][string[]] $Workspaces,[Parameter(Mandatory)][object] $Config,[AllowEmptyCollection()][string[]] $AllowedTools,[ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $AttemptId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not (Get-Command Get-EcosystemStateRoot -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Global}
$tools=if($PSBoundParameters.ContainsKey('AllowedTools')){@($AllowedTools)}else{@($Config.mcp.localServer.enabledTools | ForEach-Object {[string]$_})}
$rolePolicy=$Config.mcp.rolePolicies.PSObject.Properties[$AgentId]
$permittedTools=if($rolePolicy){@($rolePolicy.Value|Where-Object{[string]$_.server -eq 'ecosystem-read'}|ForEach-Object{@($_.tools)})}else{@()}
$tools=@($tools|Where-Object{$_ -in $permittedTools})
. (Join-Path $PSScriptRoot 'McpKnowledge.ps1')
. (Join-Path $PSScriptRoot 'Read-McpBoundSnapshot.ps1')
$task=Get-Content -LiteralPath (Join-Path $TaskRoot 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json
$repositoryIds=if($task.PSObject.Properties['repositoryIds']){@($task.repositoryIds)}elseif($task.PSObject.Properties['repositoryId']){@($task.repositoryId)}else{@()}
$sources=@(Get-McpKnowledgeSources -Config $Config -AgentId $AgentId -RepositoryIds $repositoryIds)
# Artifact access is an exact recipient context-pack contract.  A fixed list
# drifts from the host's reviewed resume plan and can either deny needed public
# evidence or expose a later role's result.  Keep role-private verifier output
# out of Reviewer sessions even if a malformed pack attempts to include it.
$contextPath=Join-Path $TaskRoot 'context-pack.json'
if(-not(Test-Path -LiteralPath $contextPath -PathType Leaf)){throw 'MCP recipient context pack is missing.'}
$contextSnapshot=Read-McpBoundSnapshot -Path $contextPath
$context=$contextSnapshot.Text|ConvertFrom-Json
if([string]$context.taskId -ne $TaskId -or [string]$context.recipient -ne $AgentId){throw 'MCP recipient context pack does not match the task and role.'}
$contextPackSha256=$contextSnapshot.Sha256
$artifacts=[Collections.Generic.List[string]]::new()
$artifactNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$artifactRevisions=[ordered]@{}
foreach($summary in @($context.artifactSummaries)){
    $artifact=if($summary.PSObject.Properties['name']){[string]$summary.name}else{''}
    if(-not $artifact -or [IO.Path]::GetFileName($artifact) -ne $artifact){throw 'MCP context pack contains an unsafe artifact name.'}
    if($AgentId -eq 'reviewer' -and $artifact -eq 'review-verification.json'){continue}
    $expectedSha=if($summary.PSObject.Properties['sha256']){[string]$summary.sha256}else{''}
    if($expectedSha -notmatch '^[a-fA-F0-9]{64}$'){throw "MCP context pack artifact '$artifact' has no valid SHA-256 fingerprint."}
    $artifactPath=Join-Path $TaskRoot $artifact
    if(-not(Test-Path -LiteralPath $artifactPath -PathType Leaf)){throw "MCP context pack artifact '$artifact' is missing."}
    $actualSha=Get-EcosystemFileSha256 -Path $artifactPath
    if($actualSha -ne $expectedSha.ToLowerInvariant()){throw "MCP context pack artifact '$artifact' revision changed before session creation."}
    if($artifactNames.Add($artifact)){$artifacts.Add($artifact);$artifactRevisions[$artifact]=$actualSha}
}
$stateRoot=Get-EcosystemStateRoot -Config $Config;$keyRoot=Join-Path $stateRoot 'health\mcp';New-Item -ItemType Directory -Path $keyRoot -Force|Out-Null;$keyPath=Join-Path $keyRoot 'session-signing.key';if(-not(Test-Path -LiteralPath $keyPath)){try{$bytes=New-Object byte[] 32;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes);$stream=[IO.File]::Open($keyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}catch [IO.IOException] { if(-not(Test-Path -LiteralPath $keyPath)){throw 'MCP session signing key could not be created.'}}catch{throw 'MCP session signing key could not be created.'}};$key=[IO.File]::ReadAllBytes($keyPath)
$doc=[ordered]@{schemaVersion=4;taskId=$TaskId;attemptId=if($AttemptId){$AttemptId}else{$RunId};agentId=$AgentId;runId=$RunId;leaseId=$LeaseId;taskRoot=[IO.Path]::GetFullPath($TaskRoot);workspaces=@($Workspaces|ForEach-Object{[IO.Path]::GetFullPath($_)});allowedTools=$tools;publicArtifacts=@($artifacts);publicArtifactRevisions=$artifactRevisions;contextPackSha256=$contextPackSha256;sources=$sources;metricsPath=(Join-Path $TaskRoot 'mcp-metrics.jsonl');signingKeyPath=$keyPath;maxCalls=[int]$Config.mcp.resilience.maxCallsPerRoleRun;maxResponseBytes=[int]$Config.mcp.resilience.maxResponseBytes;toolTimeoutSeconds=[int]$Config.mcp.resilience.toolTimeoutSeconds;createdAtUtc=[DateTime]::UtcNow.ToString('o')}
$canonical=$doc|ConvertTo-Json -Depth 8 -Compress;$hmac=[Security.Cryptography.HMACSHA256]::new($key);try{$doc.sessionHmac=([BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$hmac.Dispose()}
$path=Join-Path $TaskRoot ('mcp-session-'+$AgentId+'-'+$(if($AttemptId){$AttemptId}else{$RunId})+'.json')
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
[IO.File]::WriteAllText($path,(($doc|ConvertTo-Json -Depth 8)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{Path=$path;Session=$doc}
