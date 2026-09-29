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
function Protect-IncidentText([string]$Text){
    $safe=$Text -replace '(?i)(authorization:\s*bearer\s+)[^\s"'']+','$1[redacted]'
    return ($safe -replace '(?i)((?:token|password|secret|api[_-]?key)\s*[=:]\s*)[^\s"'']+','$1[redacted]')
}
function Get-IncidentEvidence([IO.FileInfo]$File){
    $lines=@(Get-Content -LiteralPath $File.FullName -Tail ([int]$policy.maxLogLines) -Encoding UTF8)
    if($File.Name -like 'agent-failure-*.json' -or $File.Name -like 'provider-limit-*.json'){
        return @($lines|Select-Object -Last 20|ForEach-Object{Protect-IncidentText ([string]$_)})
    }
    if($File.Name -eq 'workflow-execution-guard.json'){
        try{$guard=$lines -join [Environment]::NewLine|ConvertFrom-Json;if([bool]$guard.guardTriggered -or [int]$guard.exitCode -ne 0){return @($lines|Select-Object -Last 20|ForEach-Object{Protect-IncidentText ([string]$_)})}}catch{}
        return @()
    }
    if($File.Name -eq 'health-check-result.json'){
        try{$health=$lines -join [Environment]::NewLine|ConvertFrom-Json;$failed=@($health.Checks|Where-Object{[string]$_.Status -in @('failed','unhealthy')});if([string]$health.status -in @('failed','unhealthy') -or $failed.Count){return @($lines|Select-Object -Last 20|ForEach-Object{Protect-IncidentText ([string]$_)})}}catch{}
        return @()
    }
    $evidence=[Collections.Generic.List[string]]::new()
    foreach($line in $lines){
        $matched=$false
        try{
            $event=$line|ConvertFrom-Json -ErrorAction Stop
            $type=[string]$event.type
            if($type -in @('error','session.error','turn.failed')){$matched=$true}
            elseif($type -eq 'item.completed' -and $event.PSObject.Properties['item'] -and [string]$event.item.status -eq 'failed'){$matched=$true}
            elseif($type -eq 'result' -and $event.PSObject.Properties['is_error'] -and [bool]$event.is_error){$matched=$true}
            elseif($type -match '-stderr$' -and [string]$event.text -match $patterns){$matched=$true}
        }catch{$matched=[string]$line -match $patterns}
        if($matched){$evidence.Add((Protect-IncidentText ([string]$line)))}
    }
    return @($evidence|Select-Object -Last 20)
}
$tasksRoot=Join-Path $stateRoot 'tasks'
foreach($taskDir in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)){
    foreach($log in @(Get-ChildItem -LiteralPath $taskDir.FullName -File -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -match '^(workflow-.*\.jsonl|agent-failure-.*\.json|provider-limit-.*\.json|workflow-execution-guard\.json|health-check-result\.json)$' -and $_.LastWriteTimeUtc -ge $after
    })){
        $tail=@(Get-IncidentEvidence -File $log)
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
