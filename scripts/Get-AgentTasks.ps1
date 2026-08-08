[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [switch] $IncludeCompleted,
    [int] $EventLimit = 200,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$tasksRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'tasks'
$activeStatuses = @('created','queued','running','waiting_for_input','held','review_pending','interrupted')
$agentIds = @($config.agents | ForEach-Object { [string]$_.id })
$items = [Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
    $directories = if ($TaskId) { @(Get-Item -LiteralPath (Join-Path $tasksRoot $TaskId) -ErrorAction SilentlyContinue) } else { @(Get-ChildItem -LiteralPath $tasksRoot -Directory) }
    foreach ($directory in $directories) {
        if (-not $directory) { continue }
        $taskPath = Join-Path $directory.FullName 'task.json'
        if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { continue }
        try { $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $events = [Collections.Generic.List[object]]::new()
        $ledgerPath = Join-Path $directory.FullName 'task-ledger.jsonl'
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $events.Add(($line | ConvertFrom-Json)) } catch { }
            }
        }
        $status = if ($task.PSObject.Properties['status']) { [string]$task.status } else { 'created' }
        if (-not $TaskId -and -not $IncludeCompleted -and $status -notin $activeStatuses) { continue }
        $lastEvent = @($events | Sort-Object timestampUtc -Descending | Select-Object -First 1)
        $lastUpdated = if ($lastEvent.Count) { [string]$lastEvent[0].timestampUtc } elseif ($task.PSObject.Properties['updatedAtUtc']) { [string]$task.updatedAtUtc } else { [string]$task.createdAtUtc }
        $agentStatuses = [ordered]@{}
        foreach ($agentId in $agentIds) {
            $value = $null
            if ($task.PSObject.Properties['agentStatuses'] -and $task.agentStatuses.PSObject.Properties[$agentId]) { $value = $task.agentStatuses.$agentId }
            $agentStatuses[$agentId] = if ($value) { $value } else { [pscustomobject]@{ status='pending'; updatedAtUtc=$null; message='' } }
        }
        $artifacts = @(Get-ChildItem -LiteralPath $directory.FullName -File | Where-Object { $_.Name -notin @('task.json','task-ledger.jsonl') } | ForEach-Object { [pscustomobject]@{ name=$_.Name; path=$_.FullName; lastWriteTimeUtc=$_.LastWriteTimeUtc.ToString('o'); length=$_.Length } })
        $eventSlice = if ($EventLimit -gt 0) { @($events | Sort-Object timestampUtc -Descending | Select-Object -First $EventLimit) } else { @($events | Sort-Object timestampUtc -Descending) }
        $items.Add([pscustomobject][ordered]@{
            taskId = [string]$task.taskId
            selector = [string]$task.selector
            mode = [string]$task.mode
            repositoryId = [string]$task.repositoryId
            status = $status
            isActive = ($status -in $activeStatuses)
            currentStage = if ($task.PSObject.Properties['currentStage']) { [string]$task.currentStage } else { '' }
            lastMessage = if ($task.PSObject.Properties['lastMessage']) { [string]$task.lastMessage } elseif ($lastEvent.Count) { [string]$lastEvent[0].summary } else { '' }
            createdAtUtc = [string]$task.createdAtUtc
            updatedAtUtc = $lastUpdated
            workflowProcessId = if ($task.PSObject.Properties['workflowProcessId']) { [int]$task.workflowProcessId } else { $null }
            hasUnreadUserComments = if ($task.PSObject.Properties['hasUnreadUserComments']) { [bool]$task.hasUnreadUserComments } else { $false }
            commentCount = @($events | Where-Object { $_.type -eq 'user-comment' }).Count
            agentStatuses = [pscustomobject]$agentStatuses
            events = $eventSlice
            artifacts = $artifacts
        })
    }
}

[pscustomobject]@{ Tasks=@($items | Sort-Object updatedAtUtc -Descending); GeneratedAtUtc=[DateTime]::UtcNow.ToString('o') }

