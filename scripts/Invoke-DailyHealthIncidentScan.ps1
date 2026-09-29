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
    $safe=[string]$Text
    $safe=[regex]::Replace($safe,'(?i)(authorization\s*[:=]\s*["'']?bearer\s+)[^\s"'']+','$1[redacted]')
    $safe=[regex]::Replace($safe,'(?i)(["'']?(?:access[_-]?token|refresh[_-]?token|token|password|secret|api[_-]?key|apikey)["'']?\s*[:=]\s*["'']?)[^"''\s,}\]]+','$1[redacted]')
    $safe=[regex]::Replace($safe,'(?i)\b(?:sk|ghp|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{10,}\b','[redacted]')
    $safe=[regex]::Replace($safe,'(?i)\b[A-Z]:\\[^\s"'']+','[path]')
    return ([regex]::Replace($safe,'\s+',' ').Trim())
}
function New-IncidentEvidence([string]$Category,[string]$EventType,[string]$Detail){
    $summary=Protect-IncidentText $Detail
    if([string]::IsNullOrWhiteSpace($summary)){$summary="$Category incident detected."}
    if($summary.Length -gt 512){$summary=$summary.Substring(0,512)}
    $canonical=($Category+'|'+$EventType+'|'+$summary)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$signature=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    [pscustomobject]@{category=$Category;eventType=$EventType;signature=$signature;summary=$summary}
}
function Get-FirstIncidentText([object]$Object,[string[]]$Names){
    if($null -eq $Object){return ''}
    foreach($name in $Names){
        if($Object.PSObject.Properties[$name]){
            $value=$Object.$name
            if($null -ne $value -and ($value -is [string] -or $value -is [ValueType])){return [string]$value}
        }
    }
    return ''
}
function Get-IncidentEvidence([IO.FileInfo]$File){
    $lines=@(Get-Content -LiteralPath $File.FullName -Tail ([int]$policy.maxLogLines) -Encoding UTF8)
    if($File.Name -like 'agent-failure-*.json' -or $File.Name -like 'provider-limit-*.json'){
        $category=if($File.Name -like 'provider-limit-*'){'provider-limit'}else{'agent-failure'}
        try{
            $failure=$lines -join [Environment]::NewLine|ConvertFrom-Json
            $eventType=Get-FirstIncidentText $failure @('failureKind','category','stage','type')
            if(-not $eventType){$eventType=$category}
            $detail=Get-FirstIncidentText $failure @('failureCanonical','summary','message','reason','error','diagnostic')
            return @(New-IncidentEvidence $category $eventType $detail)
        }catch{return @(New-IncidentEvidence $category 'invalid-json' 'Incident artifact could not be parsed.')}
    }
    if($File.Name -eq 'workflow-execution-guard.json'){
        try{
            $guard=$lines -join [Environment]::NewLine|ConvertFrom-Json
            if([bool]$guard.guardTriggered -or [int]$guard.exitCode -ne 0){
                $detail=Get-FirstIncidentText $guard @('reason','failureDetail','failureKind')
                return @(New-IncidentEvidence 'execution-guard' 'guard-triggered' $detail)
            }
        }catch{return @(New-IncidentEvidence 'execution-guard' 'invalid-json' 'Execution guard artifact could not be parsed.')}
        return @()
    }
    if($File.Name -eq 'health-check-result.json'){
        try{
            $health=$lines -join [Environment]::NewLine|ConvertFrom-Json
            $failed=@($health.Checks|Where-Object{[string]$_.Status -in @('failed','unhealthy')})
            $healthStatus=Get-FirstIncidentText $health @('status','Status')
            if($healthStatus -in @('failed','unhealthy') -or $failed.Count){
                $failedNames=@($failed|ForEach-Object{Get-FirstIncidentText $_ @('Name','name','Check','check')}|Where-Object{$_})
                $detail=('status='+$healthStatus+'; failedChecks='+($failedNames -join ','))
                return @(New-IncidentEvidence 'health-check' $healthStatus $detail)
            }
        }catch{return @(New-IncidentEvidence 'health-check' 'invalid-json' 'Health result could not be parsed.')}
        return @()
    }
    $evidence=[Collections.Generic.List[object]]::new()
    foreach($line in $lines){
        $matched=$false
        $eventType='unstructured-error'
        $detail='Unstructured log entry matched an incident pattern.'
        try{
            $event=$line|ConvertFrom-Json -ErrorAction Stop
            $type=[string]$event.type
            $eventType=if($type){$type}else{'unknown-event'}
            if($type -in @('error','session.error','turn.failed')){$matched=$true}
            elseif($type -eq 'item.completed' -and $event.PSObject.Properties['item'] -and [string]$event.item.status -eq 'failed'){$matched=$true}
            elseif($type -eq 'result' -and $event.PSObject.Properties['is_error'] -and [bool]$event.is_error){$matched=$true}
            elseif($type -match '-stderr$' -and [string]$event.text -match $patterns){$matched=$true}
            if($matched){
                $detail=Get-FirstIncidentText $event @('message','error','text','reason','failure')
                if(-not $detail -and $event.PSObject.Properties['data']){$detail=Get-FirstIncidentText $event.data @('message','error','text','reason','failure')}
                if(-not $detail -and $event.PSObject.Properties['item']){$detail=Get-FirstIncidentText $event.item @('message','error','text','reason','status')}
                if(-not $detail){$detail="$eventType incident detected."}
            }
        }catch{$matched=[string]$line -match $patterns}
        if($matched){$evidence.Add((New-IncidentEvidence 'workflow-log' $eventType $detail))}
    }
    return @($evidence|Select-Object -Last 20)
}
$tasksRoot=Join-Path $stateRoot 'tasks'
foreach($taskDir in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)){
    foreach($log in @(Get-ChildItem -LiteralPath $taskDir.FullName -File -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -match '^(workflow-.*\.jsonl|agent-failure-.*\.json|provider-limit-.*\.json|workflow-execution-guard\.json|health-check-result\.json)$' -and $_.LastWriteTimeUtc -ge $after
    })){
        $evidence=@(Get-IncidentEvidence -File $log)
        if($evidence.Count){$incidents.Add([pscustomobject]@{taskId=$taskDir.Name;log=$log.Name;updatedAtUtc=$log.LastWriteTimeUtc.ToString('o');evidence=@($evidence|Select-Object -Last 20)})}
    }
}

# A clean day is intentionally a true no-op: no AI run, repair, or report file.
if(-not $incidents.Count){return [pscustomobject]@{status='no-incidents';incidentCount=0;reportPath=$null;repairs=@()}}

$repairs=[Collections.Generic.List[object]]::new()
if($Repair){
    foreach($taskId in @($incidents.taskId|Select-Object -Unique)){
        try{
            $health=& (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $taskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status=[string]$health.Status;evidence=if($health.ResultPath){[IO.Path]::GetFileName([string]$health.ResultPath)}else{$null}})
        }catch{
            $safeError=New-IncidentEvidence 'daily-repair' 'deterministic-health-failed' $_.Exception.Message
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status='failed';error=$safeError.summary;signature=$safeError.signature})
        }
        $taskRoot=Join-Path $tasksRoot $taskId
        $failure=Get-ChildItem -LiteralPath $taskRoot -Filter 'agent-failure-*.json' -File -ErrorAction SilentlyContinue|
            Where-Object{$_.LastWriteTimeUtc -ge $after}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        if(-not $failure){continue}
        try{
            # Nightly recovery may change and locally commit only the ecosystem checkout.
            # External publication and product-task restart remain explicit operator actions.
            $recovery=& (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $taskId -FailurePath $failure.FullName -SuppressExternalDelivery -SuppressTargetedResume -ConfigPath $ConfigPath -CodexHome $CodexHome
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status=[string]$recovery.Status;evidence=if($recovery.ResultPath){[IO.Path]::GetFileName([string]$recovery.ResultPath)}else{$null};commit=[string]$recovery.RecoveryCommit})
        }catch{
            $safeError=New-IncidentEvidence 'daily-repair' 'source-recovery-failed' $_.Exception.Message
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status='failed';error=$safeError.summary;signature=$safeError.signature;evidence=$failure.Name})
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
