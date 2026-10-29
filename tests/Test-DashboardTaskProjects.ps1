param([string]$ScriptPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Get-AgentTasks.ps1'), [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot), [string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/task-projects'))
$ErrorActionPreference='Stop'
$fixture=Join-Path $OutputRoot ('project-projection-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $fixture 'state'
[void](New-Item -ItemType Directory -Path (Join-Path $state 'tasks') -Force)
$config=Get-Content (Join-Path $RepositoryRoot 'config/agents.json') -Raw|ConvertFrom-Json
$config.runtime.stateRoot=$state
$config.workflow.workspaceScheduling.coordinatorStatePath=Join-Path $state 'workspace-coordinator.json'
($config.projects|Where-Object id -eq 'planning-space').name='PlanningSpace'
$configPath=Join-Path $fixture 'agents.json'
$config|ConvertTo-Json -Depth 100|Set-Content $configPath -Encoding utf8
foreach($case in @(@{id='planning';project='planning-space'},@{id='lss';project='lss'},@{id='legacy';project=$null})){
 $taskRoot=Join-Path $state ('tasks/'+$case.id)
 [void](New-Item -ItemType Directory -Path $taskRoot -Force)
 $task=[ordered]@{taskId=$case.id;selector='Synthetic task';mode='manual';repositoryIds=@('azure-planningspace-ps-excel-agent');status='created';createdAtUtc='2026-10-29T00:00:00Z';updatedAtUtc='2026-10-29T00:00:00Z';agentStatuses=@{}}
 if($case.project){$task.projectId=$case.project}
 $task|ConvertTo-Json -Depth 10|Set-Content (Join-Path $taskRoot 'task.json') -Encoding utf8
}
$before=@{}
Get-ChildItem (Join-Path $state 'tasks') -Recurse -File|ForEach-Object{$before[$_.FullName]=(Get-FileHash $_.FullName).Hash}
foreach($summary in @($true,$false)){
 $result=& $ScriptPath -Summary:$summary -IncludeCompleted -ConfigPath $configPath
 $p=@($result.Tasks|Where-Object taskId -eq planning)[0]
 if(-not $p.PSObject.Properties['projectId'] -or $p.projectId -ne 'planning-space'){throw "Summary=$summary lost persisted projectId"}
 if(-not $p.PSObject.Properties['projectName'] -or $p.projectName -ne 'PlanningSpace'){throw "Summary=$summary lost configured projectName"}
 $legacy=@($result.Tasks|Where-Object taskId -eq legacy)[0]
 if($legacy.PSObject.Properties['projectId'] -and $legacy.projectId){throw 'Genuinely legacy task must not receive an inferred project'}
}
foreach($file in $before.Keys){if((Get-FileHash $file).Hash -ne $before[$file]){throw "Read-only projection modified $file"}}
@{passed=$true;cases=@('summary project metadata','detail project metadata','genuine legacy preserved','source task files unchanged');fixture=$fixture}|ConvertTo-Json
