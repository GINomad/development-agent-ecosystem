[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$TaskId,
 [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string]$AgentId,
 [Parameter(Mandatory)][ValidateSet('routine','standard','complex','critical')][string]$Tier,
 [string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string]$CodexHome)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$routing=$config.providerRouting;if(-not $routing -or -not [bool]$routing.enabled){throw 'providerRouting must be enabled for workflow execution.'}
$agent=@($config.agents|Where-Object{[string]$_.id -eq $AgentId}|Select-Object -First 1);if(-not $agent){throw "Unknown provider-routing agent '$AgentId'."}
$providerId=if($agent.PSObject.Properties['provider'] -and [string]$agent.provider){[string]$agent.provider}else{[string]$routing.defaultProvider}
$providerProperty=$routing.providers.PSObject.Properties[$providerId];if(-not $providerProperty){throw "Agent '$AgentId' selects unsupported provider '$providerId'."};$provider=$providerProperty.Value
$tierProperty=$provider.models.PSObject.Properties[$Tier];if(-not $tierProperty){throw "Provider '$providerId' has no '$Tier' model mapping."};$mapping=$tierProperty.Value
$command=[string]$provider.command;if(-not $command){throw "Provider '$providerId' has no command."};if(-not (Get-Command $command -ErrorAction SilentlyContinue) -and -not(Test-Path -LiteralPath $command -PathType Leaf)){throw "Provider '$providerId' is not installed or its command is unavailable: $command"}
$model=[string]$mapping.model;$reasoning=[string]$mapping.reasoningEffort;if(-not $model){throw "Provider '$providerId' has no model for '$Tier'."};if(-not [bool]$provider.supportsReasoningEffort -and $reasoning -ne 'none'){throw "Provider '$providerId' does not support reasoning effort; map '$Tier' to 'none'."}
$taskRoot=Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId";if(-not(Test-Path -LiteralPath $taskRoot)){throw "Task '$TaskId' was not found."};$path=Join-Path $taskRoot ([string]$routing.artifactName)
$decision=[ordered]@{decisionId=[guid]::NewGuid().ToString('N');taskId=$TaskId;agentId=$AgentId;provider=$providerId;tier=$Tier;model=$model;reasoningEffort=$reasoning;supportsMcp=[bool]$provider.supportsMcp;command=$command;decidedAtUtc=[DateTime]::UtcNow.ToString('o')}
$document=if(Test-Path -LiteralPath $path){try{Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}catch{$null}}else{$null};if(-not $document){$document=[pscustomobject]@{schemaVersion='1.0.0';decisions=@()}}
$previous=@($document.decisions|Where-Object{[string]$_.agentId -eq $AgentId}|Select-Object -Last 1);if($previous.Count -and [string]$previous[0].provider -eq $providerId -and [string]$previous[0].tier -eq $Tier -and [string]$previous[0].model -eq $model -and [string]$previous[0].reasoningEffort -eq $reasoning){$previous[0]|Add-Member reused $true -Force;return $previous[0]}
$document.decisions=@($document.decisions)+@([pscustomobject]$decision);Write-Utf8NoBomAtomic -Path $path -Content (($document|ConvertTo-Json -Depth 12)+[Environment]::NewLine);[pscustomobject]$decision
