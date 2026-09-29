[CmdletBinding()]
param([string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/knowledge-sync'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
$shared=Join-Path $root 'shared';$local=Join-Path $root 'local';$state=Join-Path $root 'state'
foreach($base in @($shared,$local)){foreach($scope in @('global','projects/demo')){$null=New-Item -ItemType Directory -Path (Join-Path $base $scope) -Force};[IO.File]::WriteAllText((Join-Path $base 'global/rule.md'),'base')}
$scriptPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Sync-SharedKnowledge.ps1'
$parameters=@{SharedRoot=$shared;LocalRoot=$local;StateRoot=$state;ProjectId='demo'}
$first=& $scriptPath @parameters
if($first.conflicts){throw 'Identical knowledge conflicted'}
[IO.File]::WriteAllText((Join-Path $shared 'global/rule.md'),'shared update')
$receive=& $scriptPath @parameters
if($receive.received -ne 1 -or (Get-Content (Join-Path $local 'global/rule.md') -Raw) -ne 'shared update'){throw 'Inbound sync failed'}
if(@(Get-ChildItem (Join-Path (Split-Path -Parent $receive.reportPath) 'backups') -Recurse -File).Count -ne 1){throw 'Inbound backup missing'}
[IO.File]::WriteAllText((Join-Path $local 'global/rule.md'),'local verified')
$pending=& $scriptPath @parameters
if($pending.published -ne 0 -or $pending.pending -ne 1 -or (Get-Content (Join-Path $shared 'global/rule.md') -Raw) -ne 'shared update'){throw 'Unpublished local change leaked'}
$publish=& $scriptPath @parameters -PublishPaths @('global/rule.md')
if($publish.published -ne 1 -or (Get-Content (Join-Path $shared 'global/rule.md') -Raw) -ne 'local verified'){throw 'Verified reverse sync failed'}
[IO.File]::WriteAllText((Join-Path $shared 'global/rule.md'),'shared concurrent')
[IO.File]::WriteAllText((Join-Path $local 'global/rule.md'),'local concurrent')
$conflict=& $scriptPath @parameters -PublishPaths @('global/rule.md')
if($conflict.conflicts -ne 1 -or (Get-Content (Join-Path $shared 'global/rule.md') -Raw) -ne 'shared concurrent' -or (Get-Content (Join-Path $local 'global/rule.md') -Raw) -ne 'local concurrent'){throw 'Concurrent edit was overwritten'}
if(@(Get-ChildItem (Join-Path (Split-Path -Parent $conflict.reportPath) 'conflicts') -Recurse -File).Count -ne 2){throw 'Conflict evidence was not preserved'}
[IO.File]::WriteAllText((Join-Path $local 'global/rule.md'),'shared concurrent')
$resolved=& $scriptPath @parameters
if($resolved.conflicts){throw 'Reconciled conflict remained blocked'}
$newPath=Join-Path $local 'projects/demo/new.md'
[IO.File]::WriteAllText($newPath,'verified new knowledge')
$new=& $scriptPath @parameters -PublishPaths @('projects/demo/new.md')
if($new.published -ne 1){throw 'New verified record not published'}
# Delete a specific test file only, to verify that deletion is never propagated.
Remove-Item -LiteralPath $newPath
$deleted=& $scriptPath @parameters
if($deleted.conflicts -ne 1 -or -not (Test-Path (Join-Path $shared 'projects/demo/new.md'))){throw 'Deletion protection failed'}
[IO.File]::WriteAllText((Join-Path $local 'global/rule.md'),'local during lock')
$locked=[IO.File]::Open((Join-Path $shared 'global/rule.md'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$lockRejected=$false
try { try { $null=& $scriptPath @parameters -PublishPaths @('global/rule.md') } catch { $lockRejected=$true } } finally { $locked.Dispose() }
if(-not $lockRejected -or (Get-Content (Join-Path $shared 'global/rule.md') -Raw) -ne 'shared concurrent'){throw 'Concurrent writer protection failed'}
$rejected=$false
try{$null=& $scriptPath @parameters -PublishPaths @('projects/other/private.md')}catch{$rejected=$_.Exception.Message -match 'Invalid knowledge publication'}
if(-not $rejected){throw 'Cross-project publication accepted'}
[pscustomobject]@{Passed=$true;Checks=@('inbound','backup','pending-not-published','verified-outbound','concurrent-conflict','conflict-resolution','new-file','deletion-held','project-boundary');Root=$root}
