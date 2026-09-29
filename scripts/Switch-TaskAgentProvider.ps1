[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$TaskId,[Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string]$AgentId,[Parameter(Mandatory)][ValidateSet('codex','copilot','claude')][string]$Provider,[switch]$Resume,[string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string]$CodexHome)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome;$agent=@($config.agents|Where-Object{[string]$_.id -eq $AgentId})|Select-Object -First 1;if(-not $agent){throw "Unknown agent '$AgentId'."};if(-not $config.providerRouting.providers.PSObject.Properties[$Provider]){throw "Unsupported provider '$Provider'."}
$taskRoot=Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId";$taskPath=Join-Path $taskRoot 'task.json';if(-not(Test-Path -LiteralPath $taskPath)){throw "Task '$TaskId' was not found."};$task=Get-Content $taskPath -Raw -Encoding utf8|ConvertFrom-Json;$state=$task.agentStatuses.PSObject.Properties[$AgentId].Value
if([string]$state.status -eq 'running'){throw "Agent '$AgentId' is running. Stop the workflow through the dashboard to persist its checkpoint, then switch and resume it."}
if($PSCmdlet.ShouldProcess($AgentId,"Switch provider to $Provider")){
  $overridePath=Join-Path $taskRoot 'provider-overrides.json'
  $overrides=if(Test-Path -LiteralPath $overridePath){Get-Content $overridePath -Raw -Encoding utf8|ConvertFrom-Json}else{[pscustomobject]@{schemaVersion='1.0.0';agents=[pscustomobject]@{}}}
  $overrides.agents|Add-Member -NotePropertyName $AgentId -NotePropertyValue ([pscustomobject]@{provider=$Provider;changedAtUtc=[DateTime]::UtcNow.ToString('o')}) -Force
  Write-Utf8NoBomAtomic -Path $overridePath -Content (($overrides|ConvertTo-Json -Depth 12)+[Environment]::NewLine)
  $staleLimitPath=Join-Path $taskRoot ('provider-limit-'+$AgentId+'.json')
  if(Test-Path -LiteralPath $staleLimitPath -PathType Leaf){Remove-Item -LiteralPath $staleLimitPath -Force}
  & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type provider-switched -Summary "Task-scoped provider changed to '$Provider'." -Artifact $overridePath -ConfigPath $ConfigPath -CodexHome $CodexHome|Out-Null
}
if($Resume){& (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -Mode ([string]$task.mode) -TaskId $TaskId -TaskSelector ([string]$task.selector) -Resume -TargetAgentId $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome}
[pscustomobject]@{taskId=$TaskId;agentId=$AgentId;provider=$Provider;resumed=[bool]$Resume}
