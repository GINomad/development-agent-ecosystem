[CmdletBinding()]
param(
    [switch] $Repair,
    [string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy=$config.health.dailyIncidentScan
if(-not [bool]$policy.enabled){return [pscustomobject]@{status='disabled';incidentCount=0;reportPath=$null;repairs=@()}}

$stateRoot=Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$after=[DateTime]::UtcNow.AddHours(-[int]$policy.lookbackHours)
$incidents=[Collections.Generic.List[object]]::new()
$patterns='(?i)\b(failed|exception|error|quota|rate[- ]?limit|limit reached|capacity|too many requests|mcp.*fail)\b'
$tasksRoot=Join-Path $stateRoot 'tasks'
foreach($taskDir in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)){
    foreach($log in @(Get-ChildItem -LiteralPath $taskDir.FullName -File -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -match '^(workflow-.*\.jsonl|agent-failure-.*\.json|health-check-result\.json)$' -and $_.LastWriteTimeUtc -ge $after
    })){
        $tail=@(Get-Content -LiteralPath $log.FullName -Tail ([int]$policy.maxLogLines) -Encoding UTF8|Where-Object{$_ -match $patterns})
        if($tail.Count){$incidents.Add([pscustomobject]@{taskId=$taskDir.Name;log=$log.Name;path=$log.FullName;updatedAtUtc=$log.LastWriteTimeUtc.ToString('o');tail=@($tail|Select-Object -Last 20)})}
    }
}

# A clean day is intentionally a true no-op: no AI run, repair, or report file.
if(-not $incidents.Count){return [pscustomobject]@{status='no-incidents';incidentCount=0;reportPath=$null;repairs=@()}}

$repairs=[Collections.Generic.List[object]]::new()
if($Repair){
    foreach($taskId in @($incidents.taskId|Select-Object -Unique)){
        try{
            $health=& (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $taskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status=[string]$health.Status;evidence=[string]$health.ResultPath})
        }catch{
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status='failed';error=$_.Exception.Message})
        }
        $taskRoot=Join-Path $tasksRoot $taskId
        $failure=Get-ChildItem -LiteralPath $taskRoot -Filter 'agent-failure-*.json' -File -ErrorAction SilentlyContinue|
            Where-Object{$_.LastWriteTimeUtc -ge $after}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        if(-not $failure){continue}
        try{
            # Nightly recovery may change and locally commit only the ecosystem checkout.
            # External publication and product-task restart remain explicit operator actions.
            $recovery=& (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $taskId -FailurePath $failure.FullName -SuppressExternalDelivery -SuppressTargetedResume -ConfigPath $ConfigPath -CodexHome $CodexHome
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status=[string]$recovery.Status;evidence=[string]$recovery.ResultPath;commit=[string]$recovery.RecoveryCommit})
        }catch{
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status='failed';error=$_.Exception.Message;evidence=$failure.FullName})
        }
    }
}

$reportRoot=Join-Path $stateRoot 'health'
New-Item -ItemType Directory -Path $reportRoot -Force|Out-Null
$reportPath=Join-Path $reportRoot ('daily-incident-scan-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json')
$report=[ordered]@{
    schemaVersion='1.0.0';startedAtUtc=[DateTime]::UtcNow.ToString('o');lookbackHours=[int]$policy.lookbackHours
    status='incidents-found';incidents=@($incidents);repairs=@($repairs)
}
Write-Utf8NoBomAtomic -Path $reportPath -Content (($report|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
[pscustomobject]@{status=$report.status;incidentCount=$incidents.Count;reportPath=$reportPath;repairs=@($repairs)}
