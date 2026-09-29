[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $root ('.test-output/knowledge-publication/'+[guid]::NewGuid().ToString('N'))
$shared=Join-Path $fixture 'shared';$local=Join-Path $fixture 'local';$state=Join-Path $fixture 'state'
foreach($base in @($shared,$local)){foreach($scope in @('global','projects/planning-space')){$null=New-Item -ItemType Directory -Path (Join-Path $base $scope) -Force};[IO.File]::WriteAllText((Join-Path $base 'global/engineering-code-standards.md'),'base')}
$config=Get-Content (Join-Path $root 'config/agents.json') -Raw|ConvertFrom-Json
$config.runtime.stateRoot=$state
$config.runtime.hybrid.knowledgeSourceRoot=$shared
$config.knowledge.technicalRoot=Join-Path $local 'global'
$config.knowledge.globalStandardsPath=Join-Path $local 'global/engineering-code-standards.md'
$config.knowledge.versionedRoots=@((Join-Path $local 'global'),(Join-Path $local 'projects/planning-space'))
$config.projects[0].domainKnowledgeRoot=Join-Path $local 'projects/planning-space'
$configPath=Join-Path $fixture 'config.json'
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 60))
$wrapper=Join-Path $root 'scripts/Invoke-HybridKnowledgeSync.ps1'
$null=& $wrapper -ProjectId planning-space -ConfigPath $configPath
$taskRoot=Join-Path $state 'tasks/sync-publication'
$null=New-Item -ItemType Directory -Path $taskRoot -Force
$target=Join-Path $local 'global/engineering-code-standards.md'
[IO.File]::WriteAllText($target,'new verified rule')
$artifact=Join-Path $taskRoot 'knowledge-update.json'
$entry=@{id='RULE';status='proposed';statement='A rule';source='test';revision='test-revision';observedAtUtc=[DateTime]::UtcNow.ToString('o');observedBy='knowledge_keeper';targetPath=$target}
$document=@{taskId='sync-publication';entries=@($entry);humanReadable=@{title='Rules';overview='Test rules';audience='developers';updates=@()}}
[IO.File]::WriteAllText($artifact,($document|ConvertTo-Json -Depth 10))
$pending=& $wrapper -ProjectId planning-space -ConfigPath $configPath -TaskId sync-publication -KnowledgeUpdatePath $artifact
if($pending.published -ne 0 -or (Get-Content (Join-Path $shared 'global/engineering-code-standards.md') -Raw) -ne 'base'){throw 'Proposed knowledge escaped the publication gate'}
$entry.status='verified'
$document.humanReadable.updates=@(@{knowledgeId='RULE';title='Rule';description='Verified rule';applicability='global';status='verified'})
[IO.File]::WriteAllText($artifact,($document|ConvertTo-Json -Depth 10))
$published=& $wrapper -ProjectId planning-space -ConfigPath $configPath -TaskId sync-publication -KnowledgeUpdatePath $artifact
if($published.published -ne 1 -or (Get-Content (Join-Path $shared 'global/engineering-code-standards.md') -Raw) -ne 'new verified rule'){throw 'Verified publication did not synchronize'}
[pscustomobject]@{Passed=$true;ProposedBlocked=$true;VerifiedPublished=$true}
