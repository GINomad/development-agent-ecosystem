[CmdletBinding()]
param([switch]$Repair,[string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),[string]$CodexHome)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy=$config.health.dailyIncidentScan;if(-not [bool]$policy.enabled){return [pscustomobject]@{status='disabled'}}
$stateRoot=Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome;$after=[DateTime]::UtcNow.AddHours(-[int]$policy.lookbackHours);$incidents=@();$patterns='(?i)\b(failed|exception|error|quota|rate limit|capacity|mcp.*fail)\b'
foreach($taskDir in @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Directory -ErrorAction SilentlyContinue)){foreach($log in @(Get-ChildItem -LiteralPath $taskDir.FullName -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^(workflow-.*\.jsonl|agent-failure-.*\.json|health-check-result\.json)$' -and $_.LastWriteTimeUtc -ge $after})){$tail=@(Get-Content -LiteralPath $log.FullName -Tail ([int]$policy.maxLogLines) -Encoding UTF8|Where-Object{$_ -match $patterns});if($tail.Count){$incidents += [pscustomobject]@{taskId=$taskDir.Name;log=$log.Name;updatedAtUtc=$log.LastWriteTimeUtc.ToString('o');tail=@($tail|Select-Object -Last 20)}}}}
$reportRoot=Join-Path $stateRoot 'health';New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null;$reportPath=Join-Path $reportRoot ('daily-incident-scan-'+[DateTime]::UtcNow.ToString('yyyyMMdd')+'.json');$report=[ordered]@{schemaVersion='1.0.0';startedAtUtc=[DateTime]::UtcNow.ToString('o');lookbackHours=[int]$policy.lookbackHours;incidents=@($incidents);status=if($incidents.Count){'incidents-found'}else{'no-incidents'}};Write-Utf8NoBomAtomic -Path $reportPath -Content (($report|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
if($incidents.Count -and $Repair){foreach($taskId in @($incidents.taskId|Select-Object -Unique)){& (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $taskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome|Out-Null}}
[pscustomobject]@{status=$report.status;incidentCount=$incidents.Count;reportPath=$reportPath}
