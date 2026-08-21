[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [switch] $Repair,
    [switch] $ElevatedApproved,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.workflow.automaticContinuation
if (-not [bool]$policy.enabled) { return [pscustomobject]@{ Status='disabled'; Items=@() } }

$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$tasksRoot = Join-Path $stateRoot 'tasks'
$lockPath = Join-Path $stateRoot 'continuation-recovery.lock'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { return [pscustomobject]@{ Status='busy'; Items=@() } }

function Get-UtcTimestamp {
    param($Event)
    if (-not $Event -or -not $Event.PSObject.Properties['timestampUtc']) { return [DateTime]::MinValue }
    return [DateTime]::Parse([string]$Event.timestampUtc).ToUniversalTime()
}

function Get-CompletedAgentId {
    param($Request)
    foreach ($entry in @($Request.evidence)) {
        $value = [string]$entry
        if ($value.StartsWith('completed-agent:', [StringComparison]::Ordinal)) { return $value.Substring('completed-agent:'.Length) }
    }
    return $null
}

function Test-ExactHealthRepair {
    param(
        [Parameter(Mandatory)] $FailureEvent,
        [Parameter(Mandatory)][string] $TaskRoot
    )
    $failurePath = if ($FailureEvent.PSObject.Properties['artifact']) { [string]$FailureEvent.artifact } else { '' }
    if (-not $failurePath -or -not (Test-Path -LiteralPath $failurePath -PathType Leaf)) { return $false }
    try { $failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $false }
    $recoveryPath = Join-Path $TaskRoot 'health-recovery-result.json'
    if (-not (Test-Path -LiteralPath $recoveryPath -PathType Leaf)) { return $false }
    try { $recovery = Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $false }
    return [string]$recovery.status -eq 'repaired' -and
        [string]$recovery.failureSignature -eq [string]$failure.failureSignature
}

$items = [Collections.Generic.List[object]]::new()
try {
    if (-not (Test-Path -LiteralPath $tasksRoot -PathType Container)) { return [pscustomobject]@{ Status='completed'; Items=@() } }
    $directories = if ($TaskId) { @(Get-Item -LiteralPath (Join-Path $tasksRoot $TaskId) -ErrorAction SilentlyContinue) } else { @(Get-ChildItem -LiteralPath $tasksRoot -Directory) }
    foreach ($directory in $directories) {
        if (-not $directory) { continue }
        $taskPath = Join-Path $directory.FullName 'task.json'
        $ledgerPath = Join-Path $directory.FullName 'task-ledger.jsonl'
        if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { continue }
        try {
            $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $events = @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        catch {
            $items.Add([pscustomobject]@{ TaskId=$directory.Name; Status='invalid-state'; Detail=$_.Exception.Message })
            continue
        }

        $resolvedRequestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($resolved in @($events | Where-Object type -eq 'continuation-reconciled')) {
            foreach ($evidence in @($resolved.evidence)) {
                $value = [string]$evidence
                if ($value.StartsWith('continuation-event:', [StringComparison]::OrdinalIgnoreCase)) { $null = $resolvedRequestIds.Add($value.Substring('continuation-event:'.Length)) }
            }
        }

        foreach ($request in @($events | Where-Object type -eq 'continuation-requested' | Sort-Object timestampUtc)) {
            $requestId = [string]$request.eventId
            if ($resolvedRequestIds.Contains($requestId)) { continue }
            $completedAgentId = Get-CompletedAgentId -Request $request
            if ([string]::IsNullOrWhiteSpace($completedAgentId)) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='invalid-request'; RequestId=$requestId })
                continue
            }
            $requestTime = Get-UtcTimestamp -Event $request
            if ([DateTime]::UtcNow -lt $requestTime.AddSeconds([int]$policy.recoveryGraceSeconds)) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='grace-period'; RequestId=$requestId; CompletedAgentId=$completedAgentId })
                continue
            }
            $outcome = @($events | Where-Object {
                [string]$_.type -eq 'agent-result' -and [string]$_.actor -eq $completedAgentId -and
                (Get-UtcTimestamp -Event $_) -ge $requestTime -and @($_.evidence) -contains "continuation-event:$requestId"
            } | Select-Object -First 1)
            if (-not $outcome.Count) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='publication-incomplete'; RequestId=$requestId; CompletedAgentId=$completedAgentId })
                continue
            }

            $schedule = @($events | Where-Object {
                [string]$_.type -eq 'workflow-status' -and (Get-UtcTimestamp -Event $_) -gt $requestTime -and
                [string]$_.summary -like "Automatic chain continuation scheduled '*' after '$completedAgentId'."
            } | Sort-Object timestampUtc -Descending | Select-Object -First 1)
            $processAlive = $false
            if ($task.PSObject.Properties['workflowProcessId']) {
                $processId = [int]$task.workflowProcessId
                if ($processId -gt 0) { $processAlive = [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue) }
            }
            if ($processAlive) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='active-host'; RequestId=$requestId; CompletedAgentId=$completedAgentId })
                continue
            }

            $taskStatus = [string]$task.status
            if ($taskStatus -in @($policy.stopStatuses)) {
                if ($Repair) {
                    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Continuation request stopped at durable task gate '$taskStatus'." -Evidence @("continuation-event:$requestId", "result:gate:$taskStatus") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                }
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='terminal-gate'; RequestId=$requestId; CompletedAgentId=$completedAgentId; Detail=$taskStatus })
                continue
            }

            if ($schedule.Count) {
                $nextAgentId = [string]$schedule[0].targetAgentId
                $scheduleTime = Get-UtcTimestamp -Event $schedule[0]
                $nextOutcome = @($events | Where-Object { [string]$_.type -eq 'agent-result' -and [string]$_.actor -eq $nextAgentId -and (Get-UtcTimestamp -Event $_) -gt $scheduleTime } | Select-Object -First 1)
                if ($nextOutcome.Count) {
                    if ($Repair) {
                        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Continuation reached successful '$nextAgentId' outcome." -Evidence @("continuation-event:$requestId", "result:completed:$nextAgentId") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    }
                    $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='already-completed'; RequestId=$requestId; CompletedAgentId=$completedAgentId; NextAgentId=$nextAgentId })
                    continue
                }
                $nextFailure = @($events | Where-Object {
                    [string]$_.type -eq 'agent-failure' -and [string]$_.actor -eq $nextAgentId -and
                    (Get-UtcTimestamp -Event $_) -gt $scheduleTime
                } | Sort-Object timestampUtc -Descending | Select-Object -First 1)
                if ($nextFailure.Count -and -not (Test-ExactHealthRepair -FailureEvent $nextFailure[0] -TaskRoot $directory.FullName)) {
                    $failurePath = if ($nextFailure[0].PSObject.Properties['artifact']) { [string]$nextFailure[0].artifact } else { $null }
                    $items.Add([pscustomobject]@{
                        TaskId=[string]$task.taskId
                        Status='health-repair-required'
                        RequestId=$requestId
                        CompletedAgentId=$completedAgentId
                        NextAgentId=$nextAgentId
                        FailurePath=$failurePath
                        Detail='A failed scheduled agent cannot be restarted by ordinary continuation recovery until an exact-signature Health Check repair is persisted.'
                    })
                    continue
                }
                if (-not $Repair) {
                    $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='restart-required'; RequestId=$requestId; CompletedAgentId=$completedAgentId; NextAgentId=$nextAgentId })
                    continue
                }
                $repositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.PSObject.Properties['repositoryId']) { @([string]$task.repositoryId) } else { @() }
                $parameters = @{ Mode=[string]$task.mode; TaskSelector=[string]$task.selector; TaskId=[string]$task.taskId; RepositoryIds=@($repositoryIds); UserInstruction="Durable continuation recovery after '$completedAgentId'. Run only '$nextAgentId' and preserve every gate and completed artifact."; Resume=$true; TargetAgentId=$nextAgentId; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
                if ($ElevatedApproved -or [bool]$policy.useElevatedExecution) { $parameters.ElevatedApproved=$true }
                $runResult = & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @parameters
                & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Recovered scheduled continuation to '$nextAgentId'." -Evidence @("continuation-event:$requestId", "result:restarted:$nextAgentId") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='restarted'; RequestId=$requestId; CompletedAgentId=$completedAgentId; NextAgentId=$nextAgentId; Result=$runResult })
                continue
            }

            if (-not $Repair) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='continuation-required'; RequestId=$requestId; CompletedAgentId=$completedAgentId })
                continue
            }
            $continueParameters = @{ TaskId=[string]$task.taskId; CompletedAgentId=$completedAgentId; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved -or [bool]$policy.useElevatedExecution) { $continueParameters.ElevatedApproved=$true }
            $continuationResult = & (Join-Path $PSScriptRoot 'Continue-AgentChain.ps1') @continueParameters
            & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Reconciled missing continuation after '$completedAgentId' with result '$([string]$continuationResult.Status)'." -Evidence @("continuation-event:$requestId", "result:$([string]$continuationResult.Status)") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='reconciled'; RequestId=$requestId; CompletedAgentId=$completedAgentId; Result=$continuationResult })
        }
    }
}
finally { $lock.Dispose() }

[pscustomobject]@{ Status='completed'; Items=@($items) }
