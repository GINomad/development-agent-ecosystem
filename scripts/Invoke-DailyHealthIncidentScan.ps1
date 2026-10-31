[CmdletBinding()]
param(
    [switch] $Repair,
    [switch] $ThrowOnFailure,
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
    $safe=[regex]::Replace($safe,'(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b','[guid]')
    $safe=[regex]::Replace($safe,'\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b','[timestamp]')
    return ([regex]::Replace($safe,'\s+',' ').Trim())
}
function Get-EnvelopeProperty([object]$Envelope,[string]$Name){
    if($null -eq $Envelope){return $null}
    if($Envelope -is [array]){if($Envelope.Count -ne 1){throw 'Health operation must return exactly one result envelope.'};$Envelope=$Envelope[0]}
    if($Envelope.PSObject.Properties[$Name]){return $Envelope.$Name}
    if($Envelope.PSObject.Properties['Result'] -and $Envelope.Result -and $Envelope.Result.PSObject.Properties[$Name]){return $Envelope.Result.$Name}
    return $null
}
function Get-ExternalProviderFailure([IO.FileInfo]$FailureFile){
    try {
        $failure=Get-Content -LiteralPath $FailureFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json
        $text=@(
            if($failure.PSObject.Properties['summary']){[string]$failure.summary}
            if($failure.PSObject.Properties['diagnostic']){[string]$failure.diagnostic}
            if($failure.PSObject.Properties['failureCanonical']){[string]$failure.failureCanonical}
        )-join ' '
        return & (Join-Path $PSScriptRoot 'Get-ProviderFailureClassification.ps1') -Diagnostic $text
    } catch { return [pscustomobject]@{ IsExternal=$false; Category='execution' } }
}
function Write-DailyHeartbeat([string]$Status,[int]$IncidentCount,[string]$ReportPath){
    $heartPath=Join-Path $stateRoot 'health\\daily-incident-heartbeat.json'
    $heartbeat=[ordered]@{schemaVersion='1.0.0';checkedAtUtc=[DateTime]::UtcNow.ToString('o');status=$Status;incidentCount=$IncidentCount;reportPath=$ReportPath}
    New-Item -ItemType Directory -Path (Split-Path -Parent $heartPath) -Force|Out-Null
    Write-Utf8NoBomAtomic -Path $heartPath -Content (($heartbeat|ConvertTo-Json -Compress)+[Environment]::NewLine)
    return $heartPath
}
function New-IncidentEvidence([string]$Category,[string]$EventType,[string]$Detail){
    $summary=Protect-IncidentText $Detail
    if([string]::IsNullOrWhiteSpace($summary)){$summary="$Category incident detected."}
    if($summary.Length -gt 512){$summary=$summary.Substring(0,512)}
    $canonical=($Category+'|'+$EventType+'|'+$summary)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$signature=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    [pscustomobject]@{category=$Category;eventType=$EventType;signature=$signature;incidentId=('incident-'+$signature.Substring(0,16));summary=$summary}
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
$healthRoot=Join-Path $stateRoot 'health'
foreach($healthResultName in @('continuation-recovery-result.json','scheduled-review-poll.json','scheduled-review-daily.json','scheduled-review-manual.json')){
    $healthResultPath=Join-Path $healthRoot $healthResultName
    if(-not (Test-Path -LiteralPath $healthResultPath -PathType Leaf) -or (Get-Item -LiteralPath $healthResultPath).LastWriteTimeUtc -lt $after){continue}
    try {
        $healthResult=Get-Content -LiteralPath $healthResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        if([string]$healthResult.status -notin @('healthy','ok','completed','no-incidents')){
            $detail=@([string]$healthResult.status,[string]$healthResult.summary,[string]$healthResult.error.summary,(@($healthResult.errors|ForEach-Object{[string]$_.message})-join ' '))-join ' '
            $incidents.Add([pscustomobject]@{taskId=$null;log=$healthResultName;updatedAtUtc=(Get-Item -LiteralPath $healthResultPath).LastWriteTimeUtc.ToString('o');evidence=@(New-IncidentEvidence 'scheduled-health' $healthResultName $detail)})
        }
    } catch {
        $incidents.Add([pscustomobject]@{taskId=$null;log=$healthResultName;updatedAtUtc=(Get-Item -LiteralPath $healthResultPath).LastWriteTimeUtc.ToString('o');evidence=@(New-IncidentEvidence 'scheduled-health' 'invalid-json' 'Scheduled health result could not be parsed.')})
    }
}
foreach($taskDir in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)){
    foreach($log in @(Get-ChildItem -LiteralPath $taskDir.FullName -File -ErrorAction SilentlyContinue|Where-Object{
        $_.Name -match '^(workflow-.*\.jsonl|agent-failure-.*\.json|provider-limit-.*\.json|workflow-execution-guard\.json|health-check-result\.json)$' -and $_.LastWriteTimeUtc -ge $after
    })){
        $evidence=@(Get-IncidentEvidence -File $log)
        if($log.Name -like 'agent-failure-*.json'){
            try { if([string]((Get-Content -LiteralPath $log.FullName -Raw -Encoding UTF8|ConvertFrom-Json).disposition) -eq 'stale-superseded'){continue} } catch { }
        }
        if($evidence.Count){$incidents.Add([pscustomobject]@{taskId=$taskDir.Name;log=$log.Name;updatedAtUtc=$log.LastWriteTimeUtc.ToString('o');evidence=@($evidence|Select-Object -Last 20)})}
    }
}

# A clean day does not run recovery, but it leaves a small heartbeat so absence of
# incidents is distinguishable from a scheduler that never ran.
if(-not $incidents.Count){$heartbeatPath=Write-DailyHeartbeat -Status 'no-incidents' -IncidentCount 0 -ReportPath $null;return [pscustomobject]@{status='no-incidents';incidentCount=0;reportPath=$null;heartbeatPath=$heartbeatPath;repairs=@()}}

$repairs=[Collections.Generic.List[object]]::new()
if($Repair){
    foreach($taskId in @($incidents.taskId|Select-Object -Unique)){
        if([string]::IsNullOrWhiteSpace($taskId)){continue}
        $taskRoot=Join-Path $tasksRoot $taskId
        $taskPath=Join-Path $taskRoot 'task.json'
        $task=$null
        try { if(Test-Path -LiteralPath $taskPath -PathType Leaf){$task=Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8|ConvertFrom-Json} } catch { }
        if($task -and [string]$task.status -eq 'completed'){
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='recovery';status='not-applicable';reason='completed-task'})
            continue
        }
        # An expected provider condition is not an ecosystem defect. Classify it
        # before the deterministic health check, which itself performs a full
        # validation suite and must never recurse through this daily scan.
        $failure=Get-ChildItem -LiteralPath $taskRoot -Filter 'agent-failure-*.json' -File -ErrorAction SilentlyContinue|
            Where-Object{
                if($_.LastWriteTimeUtc -lt $after){return $false}
                try { return [string]((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json).disposition) -ne 'stale-superseded' } catch { return $true }
            }|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
        if($failure){
            $providerFailure=Get-ExternalProviderFailure -FailureFile $failure
            if([bool]$providerFailure.IsExternal){
                $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status='external-dependency';reason=[string]$providerFailure.Category;evidence=$failure.Name})
                continue
            }
        }
        try{
            $health=& (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') -TaskId $taskId -Repair -ConfigPath $ConfigPath -CodexHome $CodexHome
            $healthStatus=[string](Get-EnvelopeProperty -Envelope $health -Name 'status')
            if(-not $healthStatus){$healthStatus=[string](Get-EnvelopeProperty -Envelope $health -Name 'Status')}
            $healthResultPath=[string](Get-EnvelopeProperty -Envelope $health -Name 'ResultPath')
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status=$healthStatus;evidence=if($healthResultPath){[IO.Path]::GetFileName($healthResultPath)}else{$null}})
        }catch{
            $safeError=New-IncidentEvidence 'daily-repair' 'deterministic-health-failed' $_.Exception.Message
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='deterministic-health';status='failed';error=$safeError.summary;signature=$safeError.signature})
        }
        if(-not $failure){continue}
        try{
            # Nightly recovery may change and locally commit only the ecosystem checkout.
            # External publication and product-task restart remain explicit operator actions.
            $recovery=& (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $taskId -FailurePath $failure.FullName -SuppressExternalDelivery -SuppressTargetedResume -ConfigPath $ConfigPath -CodexHome $CodexHome
            $recoveryStatus=[string](Get-EnvelopeProperty -Envelope $recovery -Name 'Status')
            $recoveryResultPath=[string](Get-EnvelopeProperty -Envelope $recovery -Name 'ResultPath')
            $recoveryCommit=[string](Get-EnvelopeProperty -Envelope $recovery -Name 'RecoveryCommit')
            $repairs.Add([pscustomobject]@{taskId=$taskId;kind='source-recovery';status=$recoveryStatus;evidence=if($recoveryResultPath){[IO.Path]::GetFileName($recoveryResultPath)}else{$null};commit=$recoveryCommit})
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
    status='incidents-found';scanStatus='completed';healthStatus=if(@($repairs|Where-Object{[string]$_.kind -eq 'deterministic-health' -and [string]$_.status -eq 'unhealthy'}).Count){'unhealthy'}elseif(@($repairs|Where-Object{[string]$_.kind -eq 'deterministic-health'}).Count){'observed'}else{'not-evaluated'}
    repairStatus=if(@($repairs|Where-Object{[string]$_.status -eq 'failed'}).Count){'failed'}elseif(@($repairs|Where-Object{[string]$_.status -in @('repaired','already-repaired')}).Count){'repaired'}elseif($Repair){'not-applicable'}else{'not-requested'}
    incidents=@($incidents);repairs=@($repairs)
}
Write-Utf8NoBomAtomic -Path $reportPath -Content (($report|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
$heartbeatPath=Write-DailyHeartbeat -Status $report.status -IncidentCount $incidents.Count -ReportPath $reportPath
$result=[pscustomobject]@{status=$report.status;incidentCount=$incidents.Count;reportPath=$reportPath;heartbeatPath=$heartbeatPath;repairs=@($repairs)}
if($ThrowOnFailure -and @($repairs|Where-Object{[string]$_.status -eq 'failed'}).Count){throw "Daily incident scan completed with failed repairs. Report: $reportPath"}
return $result
