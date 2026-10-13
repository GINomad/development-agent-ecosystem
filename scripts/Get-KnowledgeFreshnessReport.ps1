[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $ProjectId,
    [hashtable] $RepositoryRoots = @{},
    [string] $OutputPath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$tasksRoot=Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'tasks'
foreach($repository in @($config.repositories)){if(-not $RepositoryRoots.ContainsKey([string]$repository.id) -and $repository.localWorkspace){$RepositoryRoots[[string]$repository.id]=[string]$repository.localWorkspace}}
function Read-Json([string]$Path){try{Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{$null}}
function Get-Head([string]$Root){$value=@(& git -C $Root rev-parse HEAD 2>$null);if($LASTEXITCODE -eq 0 -and $value.Count){([string]$value[0]).Trim()}else{''}}
$results=[Collections.Generic.List[object]]::new()
if(Test-Path -LiteralPath $tasksRoot -PathType Container){
 foreach($taskDirectory in @(Get-ChildItem -LiteralPath $tasksRoot -Directory)){
  $task=Read-Json (Join-Path $taskDirectory.FullName 'task.json');if(-not $task){continue};$taskProject=if($task.PSObject.Properties['projectId']){[string]$task.projectId}else{''};if($ProjectId -and $taskProject -ne $ProjectId){continue}
  foreach($file in @(Get-ChildItem -LiteralPath $taskDirectory.FullName -Recurse -File -Filter knowledge-update.json)){
   $knowledge=Read-Json $file.FullName;if(-not $knowledge){continue}
   foreach($entry in @($knowledge.entries)){
    $reasons=[Collections.Generic.List[string]]::new();$bindings=@(if($entry.PSObject.Properties['sourceBindings']){@($entry.sourceBindings)}else{@()});$triggers=@(if($entry.PSObject.Properties['revalidation']){@($entry.revalidation.triggers)}else{@()})
    $owner=if($entry.PSObject.Properties['owner']){[string]$entry.owner}else{''}
    if(-not $owner -or -not $bindings.Count -or -not $triggers.Count){$status='contract-metadata-missing';$reasons.Add('owner, sourceBindings, or revalidation triggers are missing')}
    else {
     foreach($binding in $bindings){
      $repositoryId=[string]$binding.repositoryId;$boundRevision=([string]$binding.revision).Replace('git:','')
      if(-not $RepositoryRoots.ContainsKey($repositoryId) -or -not (Test-Path -LiteralPath ([string]$RepositoryRoots[$repositoryId]) -PathType Container)){$reasons.Add("repository-unavailable:$repositoryId");continue}
      $root=[IO.Path]::GetFullPath([string]$RepositoryRoots[$repositoryId]);$sourcePath=[IO.Path]::GetFullPath((Join-Path $root ([string]$binding.path)))
      if(-not $sourcePath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)){$reasons.Add("source-file-missing:$repositoryId/$([string]$binding.path)")}
      $head=Get-Head $root;if(-not $head -or $head -ne $boundRevision){$reasons.Add("source-revision-changed:$repositoryId")}
     }
     if($entry.revalidation.PSObject.Properties['nextReviewAtUtc'] -and $entry.revalidation.nextReviewAtUtc){try{if([DateTime]::Parse([string]$entry.revalidation.nextReviewAtUtc).ToUniversalTime() -le [DateTime]::UtcNow){$reasons.Add('scheduled-review-due')}}catch{$reasons.Add('invalid-next-review-date')}}
     $status=if($reasons.Count){'stale'}else{'current'}
    }
    $results.Add([pscustomobject][ordered]@{taskId=[string]$task.taskId;knowledgeId=[string]$entry.id;owner=$owner;status=$status;reasons=@($reasons);sourceBindings=$bindings;revalidationTriggers=$triggers})
   }
  }
 }
}
$entries=@($results);$report=[pscustomobject][ordered]@{schemaVersion='1.0';generatedAtUtc=[DateTime]::UtcNow.ToString('o');summary=[pscustomobject][ordered]@{entryCount=$entries.Count;currentCount=@($entries|Where-Object status -eq current).Count;staleCount=@($entries|Where-Object status -eq stale).Count;metadataMissingCount=@($entries|Where-Object status -eq contract-metadata-missing).Count};entries=$entries}
if($OutputPath){$resolved=[IO.Path]::GetFullPath($OutputPath);$parent=Split-Path -Parent $resolved;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null};Write-Utf8NoBom -Path $resolved -Content (($report|ConvertTo-Json -Depth 20)+[Environment]::NewLine)}
$report
