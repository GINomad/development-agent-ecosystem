[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectId,[string]$KnowledgeUpdatePath,[string]$TaskId,[string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config/agents.json'),[string]$CodexHome)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if(-not $config.runtime.PSObject.Properties['hybrid'] -or -not $config.runtime.hybrid.enabled -or -not $config.runtime.hybrid.PSObject.Properties['knowledgeSyncEnabled'] -or -not $config.runtime.hybrid.knowledgeSyncEnabled){return [pscustomobject]@{Enabled=$false;conflicts=0;received=0;published=0}}
$project=@($config.projects|Where-Object{[string]$_.id -eq $ProjectId -and $_.enabled}|Select-Object -First 1)
if($project.Count -ne 1){throw 'Unknown knowledge synchronization project.'}
$localRoot=Split-Path -Parent (Resolve-EcosystemPath -Value ([string]$config.knowledge.technicalRoot) -Config $config -CodexHome $CodexHome)
$localProject=Resolve-EcosystemPath -Value ([string]$project[0].domainKnowledgeRoot) -Config $config -CodexHome $CodexHome
if([IO.Path]::GetFullPath($localProject) -ne [IO.Path]::GetFullPath((Join-Path $localRoot "projects/$ProjectId"))){throw 'Hybrid knowledge synchronization requires the configured managed project root.'}
$publish=[Collections.Generic.List[string]]::new()
if($KnowledgeUpdatePath){
 if(-not $TaskId){throw 'TaskId is required for verified publication.'}
 $taskRoot=Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks/$TaskId"
 $expected=Join-Path $taskRoot 'knowledge-update.json'
 if([IO.Path]::GetFullPath($KnowledgeUpdatePath) -ne [IO.Path]::GetFullPath($expected)){throw 'Knowledge publication must use the exact task artifact.'}
 & (Join-Path $PSScriptRoot 'Test-AgentOutcomeArtifact.ps1') -TaskId $TaskId -AgentId knowledge_keeper -ArtifactName knowledge-update.json -Path $expected -TaskRoot $taskRoot|Out-Null
 $knowledge=Get-Content -LiteralPath $expected -Raw|ConvertFrom-Json
 $blocked=@($knowledge.entries|Where-Object{[string]$_.status -notin @('verified','superseded')}|ForEach-Object{[string]$_.targetPath})
 foreach($entry in @($knowledge.entries|Where-Object{[string]$_.status -in @('verified','superseded')})){
  if([string]$entry.targetPath -in $blocked){throw 'A proposed and verified knowledge entry share a publication file.'}
  $value=[string]$entry.targetPath
  if(-not [IO.Path]::IsPathRooted($value) -and -not $value.StartsWith('$'+'{')){$value=Join-Path (Get-EcosystemRoot) $value}
  $target=Resolve-EcosystemPath -Value $value -Config $config -CodexHome $CodexHome
  $relative=[IO.Path]::GetRelativePath($localRoot,$target).Replace('\','/')
  if(-not (Test-Path -LiteralPath $target -PathType Leaf)){throw "Verified knowledge target is missing: $target"}
  $publish.Add($relative)
 }
}
& (Join-Path $PSScriptRoot 'Sync-SharedKnowledge.ps1') -SharedRoot (Resolve-EcosystemPath -Value ([string]$config.runtime.hybrid.knowledgeSourceRoot) -Config $config -CodexHome $CodexHome) -LocalRoot $localRoot -StateRoot (Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'knowledge-sync') -ProjectId $ProjectId -PublishPaths @($publish|Select-Object -Unique) -RepositoryRoot (Get-EcosystemRoot)
