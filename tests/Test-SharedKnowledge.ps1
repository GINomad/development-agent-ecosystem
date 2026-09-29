[CmdletBinding()]
param([string] $OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/shared-knowledge'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source'
foreach($relative in @('global','projects/selected','projects/other')){$null=New-Item -ItemType Directory -Path (Join-Path $source $relative) -Force}
$global=Join-Path $source 'global/rules.md'
$project=Join-Path $source 'projects/selected/local-uncommitted.md'
[IO.File]::WriteAllText($global,'global rule')
[IO.File]::WriteAllBytes((Join-Path $source 'projects/selected/reference.png'),[byte[]]@(137,80,78,71))
[IO.File]::WriteAllText($project,'current project knowledge')
[IO.File]::WriteAllText((Join-Path $source 'projects/other/private.md'),'other project')
$snapshotScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/New-SharedKnowledgeSnapshot.ps1'
$first=& $snapshotScript -SourceRoot $source -ProjectId selected -OutputRoot (Join-Path $root 'snapshots')
$manifest=Get-Content $first.ManifestPath -Raw|ConvertFrom-Json
if($first.FileCount -ne 3 -or @($manifest.entries|Where-Object relativePath -match 'other').Count){throw 'Project scope isolation failed'}
foreach($entry in $manifest.entries){
    if((Get-FileHash -LiteralPath $entry.snapshotPath).Hash -ne $entry.sha256 -or (Get-FileHash -LiteralPath $entry.sourcePath).Hash -ne $entry.sha256){throw 'Snapshot provenance mismatch'}
}
[IO.File]::WriteAllText($project,'updated knowledge')
$second=& $snapshotScript -SourceRoot $source -ProjectId selected -OutputRoot (Join-Path $root 'snapshots')
if((Get-Content (Join-Path $first.ProjectRoot 'local-uncommitted.md') -Raw) -ne 'current project knowledge'){throw 'Previous snapshot changed'}
if((Get-Content (Join-Path $second.ProjectRoot 'local-uncommitted.md') -Raw) -ne 'updated knowledge'){throw 'Fresh source update was not visible'}
[IO.File]::WriteAllText((Join-Path $second.ProjectRoot 'local-uncommitted.md'),'snapshot-only edit')
if((Get-Content $project -Raw) -ne 'updated knowledge'){throw 'Snapshot was linked to the source'}
$rejected=$false
try{$null=& $snapshotScript -SourceRoot $source -ProjectId selected -OutputRoot (Join-Path $source 'invalid')}catch{$rejected=$_.Exception.Message -match 'outside the source'}
if(-not $rejected){throw 'Source overwrite protection failed'}
$rejected=$false
try{$null=& $snapshotScript -SourceRoot $source -ProjectId absent -OutputRoot (Join-Path $root 'missing')}catch{$rejected=$_.Exception.Message -match 'source is missing'}
if(-not $rejected){throw 'Missing source silently accepted'}
[pscustomobject]@{Status='passed';Checks=@('selected-project-only','hash-provenance','fresh-source-updates','stable-prior-snapshot','source-unchanged','reject-source-output','missing-source')}
