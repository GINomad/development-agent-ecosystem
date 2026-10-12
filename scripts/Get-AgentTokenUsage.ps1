[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskRoot,
    [ValidateSet('agent','iteration','attempt')][string]$GroupBy='agent'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$path=Join-Path $TaskRoot 'token-usage.jsonl'
$records=@()
if(Test-Path -LiteralPath $path){
    $keys=@{}
    foreach($line in [IO.File]::ReadLines($path)){
        try{$record=$line|ConvertFrom-Json}catch{continue}
        $key=[string]$record.providerAttemptId+'|'+[string]$record.model
        if(-not $keys.ContainsKey($key)){$records+= $record;$keys[$key]=$true}
    }
}
$fields=switch($GroupBy){'agent'{@('agentId','provider','model')}'iteration'{@('iterationId','agentId','provider','model')}'attempt'{@('attemptId','providerAttemptId','agentId','provider','model')}}
$summary=@(foreach($group in @($records|Group-Object -Property $fields)){
    $first=$group.Group[0]
    $row=[ordered]@{taskId=$first.taskId}
    foreach($field in $fields){$row[$field]=$first.$field}
    $row.records=$group.Count
    $row.partialRecords=@($group.Group|Where-Object availability -eq 'partial').Count
    $row.unavailableRecords=@($group.Group|Where-Object availability -eq 'unavailable').Count
    foreach($field in @('inputTokens','outputTokens','cacheReadTokens','cacheWriteTokens','totalTokens')){
        $observed=@($group.Group|Where-Object{$null -ne $_.$field})
        $row[$field]=if($observed.Count -eq $group.Count){[long](($observed|Measure-Object -Property $field -Sum).Sum)}else{$null}
        $row['known'+$field.Substring(0,1).ToUpper()+$field.Substring(1)]=if($observed.Count){[long](($observed|Measure-Object -Property $field -Sum).Sum)}else{$null}
    }
    [pscustomobject]$row
})
[pscustomobject]@{Path=$path;GroupBy=$GroupBy;Records=$records;Summary=$summary}
