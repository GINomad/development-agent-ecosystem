[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$SharedRoot,
 [Parameter(Mandatory)][string]$LocalRoot,
 [Parameter(Mandatory)][string]$StateRoot,
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectId,
 [string[]]$PublishPaths=@(),
 [string]$RepositoryRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$shared=[IO.Path]::GetFullPath($SharedRoot).TrimEnd('\')
$local=[IO.Path]::GetFullPath($LocalRoot).TrimEnd('\')
$state=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
foreach($pair in @(@($shared,$local),@($local,$shared),@($state,$shared),@($state,$local))){
 if($pair[0].Equals($pair[1],[StringComparison]::OrdinalIgnoreCase) -or $pair[0].StartsWith($pair[1]+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Knowledge roots and sync state must be separate.'}
}
function Assert-NoLink([string]$Path) {
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked knowledge paths are not supported: $current"}}
  $current=Split-Path -Parent $current
 }
}
foreach($path in @($shared,$local,$state)){Assert-NoLink $path}
$null=New-Item -ItemType Directory -Path $state -Force
function Hash([string]$Path){if(Test-Path -LiteralPath $Path -PathType Leaf){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}else{''}}
function In-Scope([string]$Relative){
 $Relative -eq 'global' -or $Relative.StartsWith('global/') -or $Relative.StartsWith("projects/$ProjectId/")
}
foreach($relative in $PublishPaths){
 if(-not (In-Scope $relative) -or $relative -match '(^|/)\.\.(/|$)|:|\\' -or $relative.EndsWith('/.knowledge-import.json')){throw "Invalid knowledge publication path: $relative"}
}
$publishSet=@{};foreach($relative in $PublishPaths){$publishSet[$relative]=$true}
Invoke-EcosystemFileLock -LockPath (Join-Path $state 'sync.lock') -TimeoutSeconds 30 -Action {
 $run=[guid]::NewGuid().ToString('N');$runRoot=Join-Path $state "runs/$run"
 $null=New-Item -ItemType Directory -Path $runRoot -Force
 $manifestPath=Join-Path $state "baseline-$ProjectId.json"
 $baseline=@{}
 if(Test-Path -LiteralPath $manifestPath){
  $saved=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
  if([string]$saved.sharedRoot -ne $shared -or [string]$saved.localRoot -ne $local){throw 'Knowledge sync roots changed; baseline cannot be reused.'}
  foreach($entry in $saved.entries){$baseline[[string]$entry.path]=[string]$entry.hash}
 }
 $paths=@{}
 foreach($root in @($shared,$local)){
  foreach($scope in @('global',"projects/$ProjectId")){
   $folder=Join-Path $root $scope
   if(-not (Test-Path -LiteralPath $folder -PathType Container)){throw "Knowledge scope is missing: $folder"}
   $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($folder)
   while($queue.Count){
    $directory=$queue.Dequeue();Assert-NoLink $directory
    foreach($file in @(Get-ChildItem -LiteralPath $directory -Force)){
     Assert-NoLink $file.FullName
     if($file.PSIsContainer){if($file.Name -ne '.git'){$queue.Enqueue($file.FullName)};continue}
     if($file.Name -eq '.knowledge-import.json'){continue}
     $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
     $paths[$relative]=$true
    }
   }
  }
 }
 foreach($relative in $baseline.Keys){$paths[$relative]=$true}
 $actions=[Collections.Generic.List[object]]::new()
 function Copy-Checked([string]$From,[string]$To,[string]$ExpectedFrom,[string]$ExpectedTo,[string]$Relative,[string]$Direction){
  Assert-NoLink $From;Assert-NoLink $To
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force
  $inputStream=[IO.File]::Open($From,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{
   $memory=[IO.MemoryStream]::new();try{$inputStream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
   $sha=[Security.Cryptography.SHA256]::Create();try{$actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
   if($actual -ne $ExpectedFrom){throw "Knowledge source changed concurrently: $Relative"}
   $mode=if($ExpectedTo){[IO.FileMode]::Open}else{[IO.FileMode]::CreateNew}
   $outputStream=[IO.File]::Open($To,$mode,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
   try{
    $memory=[IO.MemoryStream]::new();try{$outputStream.CopyTo($memory);$previous=$memory.ToArray()}finally{$memory.Dispose()}
    if($ExpectedTo){
     $sha=[Security.Cryptography.SHA256]::Create();try{$actual=([BitConverter]::ToString($sha.ComputeHash($previous))).Replace('-','')}finally{$sha.Dispose()}
     if($actual -ne $ExpectedTo){throw "Knowledge destination changed concurrently: $Relative"}
     $backup=Join-Path $runRoot "backups/$Direction/$Relative"
     $null=New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force
     [IO.File]::WriteAllBytes($backup,$previous)
    }
    try{$outputStream.Position=0;$outputStream.Write($bytes,0,$bytes.Length);$outputStream.SetLength($bytes.Length);$outputStream.Flush($true)}
    catch{$outputStream.Position=0;$outputStream.Write($previous,0,$previous.Length);$outputStream.SetLength($previous.Length);$outputStream.Flush($true);throw}
   }finally{$outputStream.Dispose()}
  }finally{$inputStream.Dispose()}
 }
 foreach($relative in @($paths.Keys|Sort-Object)){
  if(-not (In-Scope $relative) -or $relative -match '(^|/)\.\.(/|$)|:|\\'){throw 'Sync baseline contains an out-of-scope entry.'}
  $remotePath=Join-Path $shared $relative;$localPath=Join-Path $local $relative
  $remoteHash=Hash $remotePath;$localHash=Hash $localPath
  $known=$baseline.ContainsKey($relative);$base=if($known){$baseline[$relative]}else{''}
  $action='unchanged'
  if($remoteHash -eq $localHash){$baseline[$relative]=$remoteHash}
  else{
   $canReceive=($remoteHash -and ((-not $localHash -and -not $base) -or ($known -and $localHash -eq $base)))
   if(-not $known -and $localHash -and $remoteHash -and $RepositoryRoot){
    $gitPath=[IO.Path]::GetRelativePath($RepositoryRoot,$localPath).Replace('\','/')
    $head=@(& git -C $RepositoryRoot rev-parse --verify "HEAD:$gitPath" 2>$null)
    if($LASTEXITCODE -eq 0){$working=@(& git -C $RepositoryRoot hash-object --path=$gitPath -- $localPath 2>$null);if($LASTEXITCODE -eq 0 -and $head[0] -eq $working[0]){$canReceive=$true}}
   }
   $canPublish=($publishSet.ContainsKey($relative) -and $localHash -and (($known -and $remoteHash -eq $base) -or (-not $known -and -not $remoteHash)))
   if($canReceive){Copy-Checked $remotePath $localPath $remoteHash $localHash $relative 'inbound';$baseline[$relative]=$remoteHash;$action='received'}
   elseif($canPublish){Copy-Checked $localPath $remotePath $localHash $remoteHash $relative 'outbound';$baseline[$relative]=$localHash;$action='published'}
   elseif($localHash -and (($known -and $remoteHash -eq $base) -or (-not $known -and -not $remoteHash))){$action='pending-publication'}
   else{
    $action='conflict'
    foreach($side in @('shared','local')){
     $original=if($side -eq 'shared'){$remotePath}else{$localPath}
     if(Test-Path -LiteralPath $original -PathType Leaf){$copy=Join-Path $runRoot "conflicts/$side/$relative";$null=New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force;Copy-Item -LiteralPath $original -Destination $copy}
    }
   }
  }
  $actions.Add([ordered]@{path=$relative;action=$action;sharedHash=$remoteHash;localHash=$localHash})
 }
 $document=@{sharedRoot=$shared;localRoot=$local;entries=@($baseline.Keys|Sort-Object|ForEach-Object{@{path=$_;hash=$baseline[$_]}})}
 Write-Utf8NoBomAtomic -Path $manifestPath -Content ($document|ConvertTo-Json -Depth 8)
 $result=[ordered]@{projectId=$ProjectId;runId=$run;received=@($actions|Where-Object action -eq received).Count;published=@($actions|Where-Object action -eq published).Count;conflicts=@($actions|Where-Object action -eq conflict).Count;pending=@($actions|Where-Object action -eq pending-publication).Count;reportPath=(Join-Path $runRoot 'report.json');actions=@($actions)}
 Write-Utf8NoBomAtomic -Path $result.reportPath -Content ($result|ConvertTo-Json -Depth 8)
 Write-Utf8NoBomAtomic -Path (Join-Path $state "latest-$ProjectId.json") -Content ($result|ConvertTo-Json -Depth 8)
 [pscustomobject]$result
}
