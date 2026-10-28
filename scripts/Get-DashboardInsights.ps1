[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $ProjectId,
    [ValidateRange(1,100)][int] $RecentErrorLimit = 20,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$tasksRoot = Join-Path $stateRoot 'tasks'

function Read-JsonLines {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    @([IO.File]::ReadLines($Path) | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { }
    })
}

function Read-JsonDocument {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function Get-LongValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0L
    if ([long]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    $null
}

function Get-ObjectValue {
    param($Object, [Parameter(Mandatory)][string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $property.Value
}

function Get-UtcDayKey {
    param($Record)
    $timestamp = Get-ObjectValue $Record 'timestampUtc'
    if ($null -eq $timestamp -or [string]::IsNullOrWhiteSpace([string]$timestamp)) { return $null }
    if ($timestamp -is [DateTimeOffset]) { return $timestamp.ToUniversalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    if ($timestamp -is [DateTime]) { return $timestamp.ToUniversalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse([string]$timestamp, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    $parsed.ToUniversalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Sum {
    param([object[]] $Records, [Parameter(Mandatory)][string] $Property)
    $sum = 0L
    foreach ($record in @($Records)) {
        if ($record.PSObject.Properties[$Property]) {
            $value = Get-LongValue -Value $record.$Property
            if ($null -ne $value) { $sum += $value }
        }
    }
    $sum
}

function Get-DoubleValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    $null
}

function Get-Percentile {
    param([object[]] $Records, [string] $Property, [double] $Percentile)
    $values = @($Records | ForEach-Object { Get-DoubleValue (Get-ObjectValue $_ $Property) } | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $values.Count) { return $null }
    $index = [Math]::Min($values.Count - 1, [Math]::Ceiling($Percentile * $values.Count) - 1)
    [Math]::Round([double]$values[$index], 2)
}

function New-TokenAggregate {
    param([Parameter(Mandatory)] $Group, [Parameter(Mandatory)][string] $Dimension)
    $records = @($Group.Group)
    $reported = @($records | Where-Object { [string](Get-ObjectValue $_ 'availability' '') -in @('reported','partial') -and $null -ne (Get-LongValue -Value (Get-ObjectValue $_ 'totalTokens')) })
    $first = $records | Select-Object -First 1
    $value = [ordered]@{
        recordCount = $records.Count
        reportedRecordCount = $reported.Count
        unavailableRecordCount = $records.Count - $reported.Count
        inputTokens = Get-Sum -Records $reported -Property inputTokens
        outputTokens = Get-Sum -Records $reported -Property outputTokens
        cacheReadTokens = Get-Sum -Records $reported -Property cacheReadTokens
        cacheWriteTokens = Get-Sum -Records $reported -Property cacheWriteTokens
        totalTokens = Get-Sum -Records $reported -Property totalTokens
        taskCount = @($records | ForEach-Object { [string](Get-ObjectValue $_ 'taskId' '') } | Select-Object -Unique).Count
    }
    if ($Dimension -eq 'model') {
        $value.model = [string](Get-ObjectValue $first 'model' 'unknown')
        $value.provider = [string](Get-ObjectValue $first 'provider' 'unknown')
        $value.agentCount = @($records | ForEach-Object { [string](Get-ObjectValue $_ 'agentId' 'unknown') } | Select-Object -Unique).Count
    }
    else {
        $value.agentId = [string](Get-ObjectValue $first 'agentId' 'unknown')
        $value.models = @($records | ForEach-Object { [string](Get-ObjectValue $_ 'model' '') } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    }
    [pscustomobject]$value
}

function New-DailyTokenAggregate {
    param([Parameter(Mandatory)] $Group)
    $records = @($Group.Group)
    $reported = @($records | Where-Object { [string](Get-ObjectValue $_ 'availability' '') -in @('reported','partial') -and $null -ne (Get-LongValue -Value (Get-ObjectValue $_ 'totalTokens')) })
    [pscustomobject][ordered]@{
        date = [string]$Group.Name
        recordCount = $records.Count
        reportedRecordCount = $reported.Count
        unavailableRecordCount = $records.Count - $reported.Count
        inputTokens = Get-Sum -Records $reported -Property inputTokens
        outputTokens = Get-Sum -Records $reported -Property outputTokens
        cacheReadTokens = Get-Sum -Records $reported -Property cacheReadTokens
        cacheWriteTokens = Get-Sum -Records $reported -Property cacheWriteTokens
        totalTokens = Get-Sum -Records $reported -Property totalTokens
    }
}

$taskRecords = [Collections.Generic.List[object]]::new()
$tokenRecords = [Collections.Generic.List[object]]::new()
$attemptRecords = [Collections.Generic.List[object]]::new()
$errorRecords = [Collections.Generic.List[object]]::new()
$knowledgeOutcomes = [Collections.Generic.List[object]]::new()
$mcpRecords = [Collections.Generic.List[object]]::new()
$knowledgeUsageRecords = [Collections.Generic.List[object]]::new()
$scanSummaries = [Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
    foreach ($taskDirectory in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)) {
        $task = Read-JsonDocument -Path (Join-Path $taskDirectory.FullName 'task.json')
        if (-not $task) { continue }
        $taskProjectId = if ($task.PSObject.Properties['projectId']) { [string]$task.projectId } else { '' }
        if ($ProjectId -and $taskProjectId -ne $ProjectId) { continue }
        $taskId = [string]$task.taskId
        $taskRecords.Add([pscustomobject]@{ taskId=$taskId; projectId=$taskProjectId; status=[string]$task.status; selector=[string]$task.selector; updatedAtUtc=[string]$task.updatedAtUtc })

        foreach ($record in @(Read-JsonLines -Path (Join-Path $taskDirectory.FullName 'token-usage.jsonl'))) {
            if (-not $record.PSObject.Properties['taskId']) { $record | Add-Member -NotePropertyName taskId -NotePropertyValue $taskId }
            $record | Add-Member -NotePropertyName projectId -NotePropertyValue $taskProjectId -Force
            $tokenRecords.Add($record)
        }
        foreach ($record in @(Read-JsonLines -Path (Join-Path $taskDirectory.FullName 'role-metrics.jsonl'))) {
            $eventType = [string](Get-ObjectValue $record 'eventType' '')
            $legacyRoleAttempt = -not $eventType -and -not [string]::IsNullOrWhiteSpace([string](Get-ObjectValue $record 'agentId' '')) -and [string](Get-ObjectValue $record 'status' '') -in @('succeeded','failed')
            if ($eventType -ne 'role-attempt-completed' -and -not $legacyRoleAttempt) { continue }
            $record | Add-Member -NotePropertyName projectId -NotePropertyValue $taskProjectId -Force
            $attemptRecords.Add($record)
        }
        foreach ($record in @(Read-JsonLines -Path (Join-Path $taskDirectory.FullName 'mcp-metrics.jsonl'))) {
            $record | Add-Member -NotePropertyName taskId -NotePropertyValue $taskId -Force
            $record | Add-Member -NotePropertyName projectId -NotePropertyValue $taskProjectId -Force
            $mcpRecords.Add($record)
        }
        $taskKnowledgeRecords = [Collections.Generic.List[object]]::new()
        $seenKnowledgeEvents = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($record in @(Read-JsonLines -Path (Join-Path $taskDirectory.FullName 'knowledge-usage.jsonl'))) {
            $eventId = [string](Get-ObjectValue $record 'eventId' '')
            if ($eventId -and -not $seenKnowledgeEvents.Add($eventId)) { continue }
            $record | Add-Member -NotePropertyName taskId -NotePropertyValue $taskId -Force
            $record | Add-Member -NotePropertyName projectId -NotePropertyValue $taskProjectId -Force
            $taskKnowledgeRecords.Add($record)
            $knowledgeUsageRecords.Add($record)
        }
        $repositoryRoots = @($config.repositories | ForEach-Object { [string]$_.localWorkspace })
        $workspacesRoot = Join-Path $taskDirectory.FullName 'workspaces'
        if (Test-Path -LiteralPath $workspacesRoot -PathType Container) {
            foreach ($manifestPath in @(Get-ChildItem -LiteralPath $workspacesRoot -File -Filter '*.json')) {
                $manifest = Read-JsonDocument -Path $manifestPath.FullName
                if ($manifest) { $repositoryRoots += [string](Get-ObjectValue $manifest 'clonePath' '') }
            }
        }
        $scanSummary = & (Join-Path $PSScriptRoot 'Get-RepositoryScanSummary.ps1') -Path (Join-Path $taskDirectory.FullName 'workflow-codex.jsonl') -KnowledgeRecords @($taskKnowledgeRecords) -RepositoryRoots $repositoryRoots
        $scanSummaries.Add($scanSummary)
        foreach ($scanEvent in $scanSummary.Events) {
            $scanEvent | Add-Member -NotePropertyName taskId -NotePropertyValue $taskId
            $scanEvent | Add-Member -NotePropertyName projectId -NotePropertyValue $taskProjectId
            $knowledgeUsageRecords.Add($scanEvent)
        }
        foreach ($event in @(Read-JsonLines -Path (Join-Path $taskDirectory.FullName 'task-ledger.jsonl') | Where-Object { [string]$_.type -eq 'agent-failure' })) {
            $errorRecords.Add([pscustomobject][ordered]@{
                taskId = $taskId
                projectId = $taskProjectId
                agentId = [string]$event.actor
                timestampUtc = [string]$event.timestampUtc
                summary = [string]$event.summary
                eventId = [string]$event.eventId
            })
        }

        $knowledgeEntries = [Collections.Generic.List[object]]::new()
        $knowledgeSummaries = [Collections.Generic.List[object]]::new()
        $keeperOutcomes = [Collections.Generic.List[string]]::new()
        foreach ($knowledgeFile in @(Get-ChildItem -LiteralPath $taskDirectory.FullName -Recurse -File -Filter 'knowledge-update.json' -ErrorAction SilentlyContinue)) {
            $document = Read-JsonDocument -Path $knowledgeFile.FullName
            if (-not $document) { continue }
            $relativeArtifact = (Get-EcosystemRelativePath -BasePath $taskDirectory.FullName -Path $knowledgeFile.FullName).Replace('\','/')
            foreach ($entry in @($document.entries)) {
                $knowledgeEntries.Add([pscustomobject][ordered]@{
                    id=[string]$entry.id; status=[string]$entry.status; kind=if($entry.PSObject.Properties['kind']){[string]$entry.kind}else{''}
                    statement=[string]$entry.statement; scope=if($entry.PSObject.Properties['scope']){[string]$entry.scope}else{''}
                    targetPath=[string]$entry.targetPath; source=[string]$entry.source; revision=[string]$entry.revision
                    observedAtUtc=[string]$entry.observedAtUtc; artifact=$relativeArtifact
                })
            }
            if ($document.PSObject.Properties['humanReadable'] -and $document.humanReadable) {
                foreach ($update in @($document.humanReadable.updates)) { $knowledgeSummaries.Add($update) }
            }
        }
        foreach ($summaryFile in @(Get-ChildItem -LiteralPath $taskDirectory.FullName -Recurse -File -Filter 'task-summary.json' -ErrorAction SilentlyContinue)) {
            $summary = Read-JsonDocument -Path $summaryFile.FullName
            if (-not $summary) { continue }
            foreach ($outcome in @($summary.outcomes | Where-Object { [string]$_.agentId -eq 'knowledge_keeper' })) {
                if (-not [string]::IsNullOrWhiteSpace([string]$outcome.summary) -and -not $keeperOutcomes.Contains([string]$outcome.summary)) { $keeperOutcomes.Add([string]$outcome.summary) }
            }
            if ($summary.PSObject.Properties['humanReadable'] -and $summary.humanReadable) {
                foreach ($update in @($summary.humanReadable.knowledgeUpdates)) { $knowledgeSummaries.Add($update) }
            }
        }
        if ($knowledgeEntries.Count -or $knowledgeSummaries.Count -or $keeperOutcomes.Count) {
            $latestObserved = @($knowledgeEntries | Where-Object { $_.observedAtUtc } | Sort-Object { [DateTime]$_.observedAtUtc } -Descending | Select-Object -First 1)
            $knowledgeOutcomes.Add([pscustomobject][ordered]@{
                taskId=$taskId; projectId=$taskProjectId; selector=[string]$task.selector; taskStatus=[string]$task.status
                updatedAtUtc=if($latestObserved.Count){[string]$latestObserved[0].observedAtUtc}else{[string]$task.updatedAtUtc}
                keeperOutcomes=@($keeperOutcomes); entries=@($knowledgeEntries); summaries=@($knowledgeSummaries)
            })
        }
    }
}

$modelGroups = @($tokenRecords | Group-Object { "$([string](Get-ObjectValue $_ 'provider' 'unknown'))|$([string](Get-ObjectValue $_ 'model' 'unknown'))" } | ForEach-Object { New-TokenAggregate -Group $_ -Dimension model } | Sort-Object totalTokens -Descending)
$agentGroups = @($tokenRecords | Group-Object { [string](Get-ObjectValue $_ 'agentId' 'unknown') } | ForEach-Object { New-TokenAggregate -Group $_ -Dimension agent } | Sort-Object totalTokens -Descending)
$datedTokenRecords = @($tokenRecords | Where-Object { $null -ne (Get-UtcDayKey -Record $_) })
$dailyTokenGroups = @($datedTokenRecords | Group-Object { Get-UtcDayKey -Record $_ } | ForEach-Object { New-DailyTokenAggregate -Group $_ } | Sort-Object date)
$failedAttempts = @($attemptRecords | Where-Object { [string](Get-ObjectValue $_ 'status' '') -eq 'failed' })
$attemptsByAgent = @($attemptRecords | Group-Object { [string](Get-ObjectValue $_ 'agentId' 'unknown') } | ForEach-Object {
    $records = @($_.Group); $failed = @($records | Where-Object { [string](Get-ObjectValue $_ 'status' '') -eq 'failed' }).Count
    [pscustomobject]@{ agentId=[string]$_.Name; attempts=$records.Count; failed=$failed; succeeded=$records.Count-$failed; errorRate=if($records.Count){[Math]::Round($failed/$records.Count,4)}else{0} }
} | Sort-Object @{Expression='failed';Descending=$true}, agentId)
$errorsByAgent = @($errorRecords | Group-Object agentId | ForEach-Object { [pscustomobject]@{ agentId=[string]$_.Name; count=$_.Count } } | Sort-Object @{Expression='count';Descending=$true}, agentId)
$reportedTokens = @($tokenRecords | Where-Object { [string](Get-ObjectValue $_ 'availability' '') -in @('reported','partial') -and $null -ne (Get-LongValue -Value (Get-ObjectValue $_ 'totalTokens')) })
$allKnowledgeEntries = @($knowledgeOutcomes | ForEach-Object { @($_.entries) })

$mcpToolRecords = @($mcpRecords | Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-ObjectValue $_ 'tool' '')) })
$mcpTransportRecords = @($mcpRecords | Where-Object { [string]::IsNullOrWhiteSpace([string](Get-ObjectValue $_ 'tool' '')) })
$mcpSucceeded = @($mcpToolRecords | Where-Object { [string](Get-ObjectValue $_ 'status' '') -in @('succeeded','success','completed') })
$mcpFailed = @($mcpToolRecords | Where-Object { [string](Get-ObjectValue $_ 'status' '') -notin @('succeeded','success','completed') })
$mcpTransportFailures = @($mcpTransportRecords | Where-Object { [string](Get-ObjectValue $_ 'status' '') -notin @('succeeded','success','completed') })
$mcpFallbacks = @($mcpRecords | Where-Object { [bool](Get-ObjectValue $_ 'fallbackUsed' $false) })
$mcpByTool = @($mcpToolRecords | Group-Object { "$(Get-ObjectValue $_ 'server' 'unknown')|$(Get-ObjectValue $_ 'tool' 'unknown')" } | ForEach-Object {
    $records = @($_.Group); $success = @($records | Where-Object { [string](Get-ObjectValue $_ 'status' '') -in @('succeeded','success','completed') }).Count
    [pscustomobject][ordered]@{ server=([string]$_.Name -split '\|',2)[0]; tool=([string]$_.Name -split '\|',2)[1]; calls=$records.Count; succeeded=$success; failed=$records.Count-$success; errorRate=if($records.Count){[Math]::Round(($records.Count-$success)/$records.Count,4)}else{0}; p50LatencyMs=Get-Percentile $records 'durationMs' .50; p95LatencyMs=Get-Percentile $records 'durationMs' .95; responseBytes=Get-Sum -Records $records -Property responseBytes }
} | Sort-Object @{Expression='calls';Descending=$true}, server, tool)
$mcpByAgent = @($mcpToolRecords | Group-Object { [string](Get-ObjectValue $_ 'agentId' 'unknown') } | ForEach-Object {
    $records = @($_.Group); $success = @($records | Where-Object { [string](Get-ObjectValue $_ 'status' '') -in @('succeeded','success','completed') }).Count
    [pscustomobject][ordered]@{ agentId=[string]$_.Name; calls=$records.Count; succeeded=$success; failed=$records.Count-$success; errorRate=if($records.Count){[Math]::Round(($records.Count-$success)/$records.Count,4)}else{0}; p95LatencyMs=Get-Percentile $records 'durationMs' .95 }
} | Sort-Object @{Expression='calls';Descending=$true}, agentId)
$knowledgeBySource = @($knowledgeUsageRecords | Group-Object { "$(Get-ObjectValue $_ 'sourceKind' 'unknown')|$(Get-ObjectValue $_ 'sourceId' 'unknown')" } | ForEach-Object {
    $records = @($_.Group); $parts = [string]$_.Name -split '\|',2; $reused=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'reused' }).Count; $built=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'rebuilt' }).Count; $selected=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'selected' }).Count; $read=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -in @('read','used') }).Count
    [pscustomobject][ordered]@{ sourceKind=$parts[0]; sourceId=$parts[1]; events=$records.Count; selected=$selected; read=$read; reused=$reused; rebuilt=$built; fullScan=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'full-scan' }).Count; agents=@($records | ForEach-Object { [string](Get-ObjectValue $_ 'agentId' '') } | Where-Object { $_ } | Select-Object -Unique | Sort-Object) }
} | Sort-Object @{Expression='events';Descending=$true}, sourceKind, sourceId)
$knowledgeByAgent = @($knowledgeUsageRecords | Group-Object { [string](Get-ObjectValue $_ 'agentId' 'unknown') } | ForEach-Object {
    $records = @($_.Group); [pscustomobject][ordered]@{ agentId=[string]$_.Name; events=$records.Count; skills=@($records | Where-Object { [string](Get-ObjectValue $_ 'sourceKind' '') -eq 'skill' }).Count; knowledge=@($records | Where-Object { [string](Get-ObjectValue $_ 'sourceKind' '') -eq 'knowledge' }).Count; mapReused=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'reused' }).Count; mapBuilt=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'rebuilt' }).Count; fullScans=@($records | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'full-scan' }).Count }
} | Sort-Object @{Expression='events';Descending=$true}, agentId)
$mapEvents = @($knowledgeUsageRecords | Where-Object { [string](Get-ObjectValue $_ 'sourceKind' '') -eq 'repository-map' })
$mapReusedCount = @($mapEvents | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'reused' }).Count
$mapBuiltCount = @($mapEvents | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -eq 'rebuilt' }).Count
$fullScanCount = Get-Sum -Records @($scanSummaries) -Property FullScanCount
$scanMapEventCount = Get-Sum -Records @($scanSummaries) -Property MapEventCount
$mapEligibleCount = $mapReusedCount + $mapBuiltCount
$knowledgeSummary = [pscustomobject][ordered]@{
    eventCount=$knowledgeUsageRecords.Count; taskCount=@($knowledgeUsageRecords | ForEach-Object { [string](Get-ObjectValue $_ 'taskId' '') } | Where-Object { $_ } | Select-Object -Unique).Count; skillSelectionCount=@($knowledgeUsageRecords | Where-Object { [string](Get-ObjectValue $_ 'sourceKind' '') -eq 'skill' -and [string](Get-ObjectValue $_ 'accessMode' '') -eq 'selected' }).Count; sourceReadCount=@($knowledgeUsageRecords | Where-Object { [string](Get-ObjectValue $_ 'accessMode' '') -in @('read','used') }).Count; mapReusedCount=$mapReusedCount; mapBuiltCount=$mapBuiltCount; mapReuseRate=if($mapEligibleCount){[Math]::Round($mapReusedCount/$mapEligibleCount,4)}else{$null}; fullScanCount=$fullScanCount; scanAvoidanceRate=if($scanMapEventCount+$fullScanCount){[Math]::Round($scanMapEventCount/($scanMapEventCount+$fullScanCount),4)}else{$null}; scanMeasurement='attempt-covered-terminal-command-heuristic'; scanMapEventCount=$scanMapEventCount; scanCoveredAttemptCount=(Get-Sum -Records @($scanSummaries) -Property CoveredAttemptCount); targetedSearchCount=(Get-Sum -Records @($scanSummaries) -Property TargetedSearchCount); scanExcludedCommandCount=(Get-Sum -Records @($scanSummaries) -Property ExcludedCommandCount); scanUnclassifiedCommandCount=(Get-Sum -Records @($scanSummaries) -Property UnclassifiedCommandCount); scanExcludedMapEventCount=(Get-Sum -Records @($scanSummaries) -Property ExcludedMapEventCount); sourceCount=@($knowledgeUsageRecords | ForEach-Object { "$(Get-ObjectValue $_ 'sourceKind' '')|$(Get-ObjectValue $_ 'sourceId' '')" } | Select-Object -Unique).Count
}
$mcpSummary = [pscustomobject][ordered]@{
    callCount=$mcpToolRecords.Count; succeededCount=$mcpSucceeded.Count; failedCount=$mcpFailed.Count; successRate=if($mcpToolRecords.Count){[Math]::Round($mcpSucceeded.Count/$mcpToolRecords.Count,4)}else{$null}; errorRate=if($mcpToolRecords.Count){[Math]::Round($mcpFailed.Count/$mcpToolRecords.Count,4)}else{$null}; fallbackCount=$mcpFallbacks.Count; transportEventCount=$mcpTransportRecords.Count; transportFailureCount=$mcpTransportFailures.Count; transportFailureRate=if($mcpTransportRecords.Count){[Math]::Round($mcpTransportFailures.Count/$mcpTransportRecords.Count,4)}else{$null}; p50LatencyMs=Get-Percentile $mcpToolRecords 'durationMs' .50; p95LatencyMs=Get-Percentile $mcpToolRecords 'durationMs' .95; requestBytes=Get-Sum -Records $mcpToolRecords -Property requestBytes; responseBytes=Get-Sum -Records $mcpToolRecords -Property responseBytes; serverCount=@($mcpToolRecords | ForEach-Object { [string](Get-ObjectValue $_ 'server' '') } | Where-Object { $_ } | Select-Object -Unique).Count; toolCount=@($mcpToolRecords | ForEach-Object { "$(Get-ObjectValue $_ 'server' '')|$(Get-ObjectValue $_ 'tool' '')" } | Select-Object -Unique).Count
}

[pscustomobject][ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    projectId = if($ProjectId){$ProjectId}else{$null}
    analytics = [pscustomobject][ordered]@{
        summary = [pscustomobject][ordered]@{
            taskCount=$taskRecords.Count; completedTaskCount=@($taskRecords | Where-Object status -eq 'completed').Count
            activeTaskCount=@($taskRecords | Where-Object { $_.status -notin @('completed','cancelled') }).Count
            errorCount=$errorRecords.Count; failedAttemptCount=$failedAttempts.Count; attemptCount=$attemptRecords.Count
            totalTokens=Get-Sum -Records $reportedTokens -Property totalTokens
            reportedTokenRecordCount=$reportedTokens.Count; unavailableTokenRecordCount=$tokenRecords.Count-$reportedTokens.Count
            unassignedTokenTimestampRecordCount=$tokenRecords.Count-$datedTokenRecords.Count
            knowledgeOutcomeCount=$knowledgeOutcomes.Count
        }
        tokensByDay=$dailyTokenGroups; tokensByModel=$modelGroups; tokensByAgent=$agentGroups; attemptsByAgent=$attemptsByAgent; errorsByAgent=$errorsByAgent
        recentErrors=@($errorRecords | Sort-Object { if($_.timestampUtc){[DateTime]$_.timestampUtc}else{[DateTime]::MinValue} } -Descending | Select-Object -First $RecentErrorLimit)
        mcp=$mcpSummary; mcpByTool=$mcpByTool; mcpByAgent=$mcpByAgent
        knowledgeUsage=$knowledgeSummary; knowledgeBySource=$knowledgeBySource; knowledgeByAgent=$knowledgeByAgent
    }
    knowledge = [pscustomobject][ordered]@{
        outcomeCount=$knowledgeOutcomes.Count
        verifiedEntryCount=@($allKnowledgeEntries | Where-Object status -eq 'verified').Count
        proposedEntryCount=@($allKnowledgeEntries | Where-Object status -eq 'proposed').Count
        supersededEntryCount=@($allKnowledgeEntries | Where-Object status -eq 'superseded').Count
        outcomes=@($knowledgeOutcomes | Sort-Object { if($_.updatedAtUtc){[DateTime]$_.updatedAtUtc}else{[DateTime]::MinValue} } -Descending)
    }
}
