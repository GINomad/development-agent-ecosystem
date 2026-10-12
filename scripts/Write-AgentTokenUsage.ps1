[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskRoot,
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][string] $AgentId,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $AttemptId,
    [Parameter(Mandatory)][string] $Provider,
    [Parameter(Mandatory)][string] $Model,
    [Parameter(Mandatory)][string] $LogPath,
    [string] $UsagePath,
    [Nullable[int]] $TaskRevision
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
function Get-Count($Value, [string[]]$Names) {
    foreach ($name in $Names) {
        if ($Value -and $Value.PSObject.Properties[$name] -and $null -ne $Value.$name) {
            $number = 0L
            if ([long]::TryParse([string]$Value.$name, [ref]$number) -and $number -ge 0) { return $number }
        }
    }
    return $null
}
function New-Usage($Usage, $SelectedModel, $Source) {
    [pscustomobject]@{
        model=$SelectedModel; source=$Source
        inputTokens=(Get-Count $Usage @('input_tokens','inputTokens','promptTokens'))
        outputTokens=(Get-Count $Usage @('output_tokens','outputTokens','completionTokens'))
        cacheReadTokens=(Get-Count $Usage @('cache_read_input_tokens','cached_input_tokens','cacheReadInputTokens'))
        cacheWriteTokens=(Get-Count $Usage @('cache_creation_input_tokens','cache_write_input_tokens','cacheCreationInputTokens'))
    }
}
$events = [Collections.Generic.List[object]]::new()
$selected = $false
if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($LogPath)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $event -or -not $event.PSObject.Properties['type']) { continue }
        if ([string]$event.type -eq 'ecosystem-workflow-run') {
            $selected = $event.PSObject.Properties['attemptId'] -and [string]$event.attemptId -eq $AttemptId
        }
        if ($selected) { $events.Add($event) }
    }
}
$segments = [Collections.Generic.List[object]]::new()
$segment = [pscustomobject]@{ id=$AttemptId; model=$Model; events=[Collections.Generic.List[object]]::new() }
foreach ($event in $events) {
    if ([string]$event.type -eq 'ecosystem-provider-attempt') {
        if ($segment.events.Count) { $segments.Add($segment) }
        $segment = [pscustomobject]@{ id=[string]$event.providerAttemptId; model=[string]$event.model; events=[Collections.Generic.List[object]]::new() }
    } elseif ([string]$event.type -ne 'ecosystem-workflow-run') { $segment.events.Add($event) }
}
$segments.Add($segment)
$records = [Collections.Generic.List[object]]::new()
foreach ($part in $segments) {
    $usages = @()
    if ($Provider -eq 'claude') {
        $terminal = @($part.events | Where-Object { [string]$_.type -eq 'result' }) | Select-Object -Last 1
        if ($terminal -and $terminal.PSObject.Properties['modelUsage'] -and $terminal.modelUsage) {
            foreach ($entry in $terminal.modelUsage.PSObject.Properties) { $usages += New-Usage $entry.Value $entry.Name 'claude-result-modelUsage' }
        } elseif ($terminal -and $terminal.PSObject.Properties['usage']) {
            $usages += New-Usage $terminal.usage $part.model 'claude-result-usage'
        } else {
            # Interrupted streams: keep the latest counters for each message, never sum snapshots of the same message.
            $messages = @{}
            foreach ($event in $part.events) {
                if ([string]$event.type -ne 'assistant' -or -not $event.PSObject.Properties['message']) { continue }
                $message=$event.message
                if ($message.PSObject.Properties['id'] -and $message.PSObject.Properties['usage']) { $messages[[string]$message.id]=$message }
            }
            foreach ($message in $messages.Values) {
                $actualModel=if($message.PSObject.Properties['model']){[string]$message.model}else{$part.model}
                $usages += New-Usage $message.usage $actualModel 'claude-message-partial'
            }
        }
    } elseif ($Provider -eq 'codex') {
        foreach ($event in $part.events) {
            if ([string]$event.type -eq 'turn.completed' -and $event.PSObject.Properties['usage']) { $usages += New-Usage $event.usage $part.model 'codex-turn-completed' }
        }
    } elseif ($Provider -eq 'copilot' -and $UsagePath -and (Test-Path -LiteralPath $UsagePath -PathType Leaf)) {
        try {
            $usage = Get-Content -LiteralPath $UsagePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($usage.PSObject.Properties['usage']) { $usage=$usage.usage }
            $usages += New-Usage $usage $part.model 'copilot-usage-file'
        } catch { }
    }
    if (-not $usages.Count) { $usages = @(New-Usage $null $part.model 'unavailable') }
    foreach ($group in @($usages | Group-Object model)) {
        $counts = [ordered]@{}
        foreach ($field in @('inputTokens','outputTokens','cacheReadTokens','cacheWriteTokens')) {
            $observed = @($group.Group | Where-Object { $null -ne $_.$field })
            $counts[$field] = if ($observed.Count -eq $group.Count) { [long](($observed | Measure-Object -Property $field -Sum).Sum) } else { $null }
        }
        $sources=@($group.Group.source | Select-Object -Unique)
        $available=$null -ne $counts.inputTokens -and $null -ne $counts.outputTokens
        $total=$null
        # Claude input excludes cache counters; Codex input already includes cached tokens.
        if ($available -and ($Provider -ne 'claude' -or ($null -ne $counts.cacheReadTokens -and $null -ne $counts.cacheWriteTokens))) {
            $total=[long]$counts.inputTokens+[long]$counts.outputTokens
            if($Provider -eq 'claude') { $total += [long]$counts.cacheReadTokens+[long]$counts.cacheWriteTokens }
        }
        $records.Add([pscustomobject][ordered]@{
            schemaVersion=1; timestampUtc=[DateTime]::UtcNow.ToString('o'); taskId=$TaskId
            iterationId=$RunId; runId=$RunId; taskRevision=$TaskRevision; agentId=$AgentId; attemptId=$AttemptId; providerAttemptId=$part.id
            provider=$Provider; requestedModel=$part.model; model=$group.Name
            availability=if(-not $available){'unavailable'}elseif($sources -contains 'claude-message-partial'){'partial'}else{'reported'}
            inputTokens=$counts.inputTokens; outputTokens=$counts.outputTokens
            cacheReadTokens=$counts.cacheReadTokens; cacheWriteTokens=$counts.cacheWriteTokens; totalTokens=$total
            sources=$sources; logPath=[IO.Path]::GetFullPath($LogPath)
        })
    }
}
$path=Join-Path $TaskRoot 'token-usage.jsonl'
Invoke-EcosystemFileLock -LockPath ($path+'.lock') -TimeoutSeconds 30 -Action {
    $keys=@{}
    if(Test-Path -LiteralPath $path) {
        foreach($line in [IO.File]::ReadLines($path)) {
            try { $old=$line|ConvertFrom-Json; $keys[([string]$old.providerAttemptId+'|'+[string]$old.model)]=$true } catch { }
        }
    }
    foreach($record in $records) {
        $key=$record.providerAttemptId+'|'+$record.model
        if(-not $keys.ContainsKey($key)) {
            [IO.File]::AppendAllText($path,($record|ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
            $keys[$key]=$true
        }
    }
} | Out-Null
[pscustomobject]@{ Path=$path; Records=@($records) }
