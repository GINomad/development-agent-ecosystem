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

function Convert-TaskRuntimeUtc {
    param([Parameter(Mandatory)] $Value)
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
}

function Test-TaskRuntimeFile {
    param([Parameter(Mandatory)][string] $TaskRoot, [Parameter(Mandatory)][string] $Path)
    $resolvedRoot = [IO.Path]::GetFullPath($TaskRoot).TrimEnd([char[]]@('\','/'))
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($candidate in @($resolvedRoot, $resolvedPath)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Any)) { return $false }
        if (((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    return $true
}

function Resolve-TaskContinuationConfig {
    param([Parameter(Mandatory)] $Task, [Parameter(Mandatory)][string] $TaskRoot)
    $runId = if ($Task.PSObject.Properties['executionRunId']) { [string]$Task.executionRunId } else { '' }
    $leaseId = if ($Task.PSObject.Properties['workspaceLeaseId']) { [string]$Task.workspaceLeaseId } else { '' }
    if ([string]::IsNullOrWhiteSpace($runId) -and [string]::IsNullOrWhiteSpace($leaseId)) {
        return [pscustomobject]@{ Status='legacy'; ConfigPath=$ConfigPath; Config=$config; Policy=$config.workflow.automaticContinuation }
    }
    if ($runId -notmatch '^[A-Za-z0-9._-]{12,128}$' -or [string]::IsNullOrWhiteSpace($leaseId)) {
        return [pscustomobject]@{ Status='config-unavailable'; Detail='The active task execution identity is incomplete or unsafe.' }
    }
    $contextPath = Join-Path $TaskRoot "execution-context-$runId.json"
    $snapshotPath = Join-Path $TaskRoot "execution-config-$runId.json"
    if ([string]::IsNullOrWhiteSpace($leaseId) -or -not (Test-TaskRuntimeFile -TaskRoot $TaskRoot -Path $contextPath) -or -not (Test-TaskRuntimeFile -TaskRoot $TaskRoot -Path $snapshotPath)) {
        return [pscustomobject]@{ Status='config-unavailable'; Detail='The active task execution context or its task-root configuration snapshot is missing or unsafe.' }
    }
    try { $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return [pscustomobject]@{ Status='config-unavailable'; Detail='The active task execution context is not valid JSON.' } }
    if ($null -eq $context -or $context -is [Collections.IEnumerable] -or $context -isnot [psobject]) { return [pscustomobject]@{ Status='config-unavailable'; Detail='The active task execution context must be one JSON object.' } }
    $taskRepositoryIds = if ($Task.PSObject.Properties['repositoryIds']) { @($Task.repositoryIds | ForEach-Object { [string]$_ }) } elseif ($Task.PSObject.Properties['repositoryId']) { @([string]$Task.repositoryId) } else { @() }
    $taskProjectId = if ($Task.PSObject.Properties['projectId']) { [string]$Task.projectId } else { '' }
    $contextRepositoryIds = if ($context.PSObject.Properties['repositories']) { @($context.repositories | ForEach-Object { [string]$_.repositoryId }) } else { @() }
    $contextSnapshotPath = if ($context.PSObject.Properties['configSnapshotPath']) { [string]$context.configSnapshotPath } else { '' }
    $contextTaskId = if ($context.PSObject.Properties['taskId']) { [string]$context.taskId } else { '' }
    $contextProjectId = if ($context.PSObject.Properties['projectId']) { [string]$context.projectId } else { '' }
    $contextRunId = if ($context.PSObject.Properties['runId']) { [string]$context.runId } else { '' }
    $contextLeaseId = if ($context.PSObject.Properties['leaseId']) { [string]$context.leaseId } else { '' }
    if ($contextTaskId -ne [string]$Task.taskId -or $contextProjectId -ne $taskProjectId -or $contextRunId -ne $runId -or $contextLeaseId -ne $leaseId -or $contextSnapshotPath -ne $snapshotPath -or ($taskRepositoryIds -join '|') -ne ($contextRepositoryIds -join '|')) {
        return [pscustomobject]@{ Status='config-unavailable'; Detail='The active task execution context does not match the persisted task run, lease, project, scope, or snapshot path.' }
    }
    try { $taskConfig = Get-EcosystemConfig -ConfigPath $snapshotPath -CodexHome $CodexHome } catch { return [pscustomobject]@{ Status='config-unavailable'; Detail='The task configuration snapshot is invalid.' } }
    if (-not [string]::Equals((Get-EcosystemStateRoot -Config $taskConfig -CodexHome $CodexHome), $stateRoot, [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Status='config-unavailable'; Detail='The task configuration snapshot points at a different state root.' } }
    if (-not $taskProjectId -or -not @($taskConfig.projects | Where-Object { [string]$_.id -eq $taskProjectId }).Count) { return [pscustomobject]@{ Status='config-unavailable'; Detail='The task configuration snapshot does not contain the persisted project.' } }
    return [pscustomobject]@{ Status='snapshot'; ConfigPath=$snapshotPath; Config=$taskConfig; Policy=$taskConfig.workflow.automaticContinuation }
}

function Test-LiveTaskController {
    param([Parameter(Mandatory)] $Task, [Parameter(Mandatory)] $TaskConfig)
    $runId = if ($Task.PSObject.Properties['executionRunId']) { [string]$Task.executionRunId } else { '' }
    $leaseId = if ($Task.PSObject.Properties['workspaceLeaseId']) { [string]$Task.workspaceLeaseId } else { '' }
    $coordinatorPath = Resolve-EcosystemPath -Value ([string]$TaskConfig.workflow.workspaceScheduling.coordinatorStatePath) -Config $TaskConfig -CodexHome $CodexHome
    $lease = $null
    if ($runId -and $leaseId -and (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) {
        try {
            $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lease = @($coordinator.leases | Where-Object { [string]$_.taskId -eq [string]$Task.taskId -and [string]$_.runId -eq $runId -and [string]$_.leaseId -eq $leaseId } | Select-Object -First 1)
            if ($lease.Count) { $lease = $lease[0] } else { $lease = $null }
        } catch { }
    }
    if ($lease -and $lease.PSObject.Properties['controllerProcessId'] -and $lease.PSObject.Properties['controllerStartedAtUtc']) {
        try {
            $process = Get-Process -Id ([int]$lease.controllerProcessId) -ErrorAction Stop
            $recorded = Convert-TaskRuntimeUtc -Value $lease.controllerStartedAtUtc
            if ([Math]::Abs(($process.StartTime.ToUniversalTime() - $recorded).TotalSeconds) -lt 2) { return 'active-controller' }
        } catch { }
    }
    if ($lease) {
        try {
            $heartbeatValues = @()
            if ($lease.PSObject.Properties['heartbeatAtUtc']) { $heartbeatValues += Convert-TaskRuntimeUtc -Value $lease.heartbeatAtUtc }
            if ($Task.PSObject.Properties['workflowHeartbeatAtUtc']) { $heartbeatValues += Convert-TaskRuntimeUtc -Value $Task.workflowHeartbeatAtUtc }
            if ($heartbeatValues.Count -and ([DateTime]::UtcNow - ($heartbeatValues | Sort-Object -Descending | Select-Object -First 1)).TotalSeconds -lt [int]$TaskConfig.workflow.workspaceScheduling.staleLeaseGraceSeconds) { return 'fresh-lease-heartbeat' }
        } catch { }
    }
    if ($Task.PSObject.Properties['workflowProcessId']) {
        try {
            $workflowProcessId = [int]$Task.workflowProcessId
            if ($workflowProcessId -gt 0 -and (Get-Process -Id $workflowProcessId -ErrorAction Stop)) { return 'legacy-workflow-pid' }
        } catch { }
    }
    return $null
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

        $runtimeConfig = Resolve-TaskContinuationConfig -Task $task -TaskRoot $directory.FullName
        if ([string]$runtimeConfig.Status -eq 'config-unavailable') {
            $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='config-unavailable'; Detail=[string]$runtimeConfig.Detail })
            continue
        }
        $taskConfigPath = [string]$runtimeConfig.ConfigPath
        $taskConfig = $runtimeConfig.Config
        $taskPolicy = $runtimeConfig.Policy
        if (-not [bool]$taskPolicy.enabled) {
            $pipelineEnabled = if ($taskConfig.PSObject.Properties['pipeline'] -and $taskConfig.pipeline.PSObject.Properties['enabled']) { [bool]$taskConfig.pipeline.enabled } else { $false }
            $automaticRecoveryEnabled = if ($taskConfig.PSObject.Properties['health'] -and $taskConfig.health.PSObject.Properties['automaticRecovery'] -and $taskConfig.health.automaticRecovery.PSObject.Properties['enabled']) { [bool]$taskConfig.health.automaticRecovery.enabled } else { $false }
            $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='disabled'; ConfigPath=$taskConfigPath; PipelineEnabled=$pipelineEnabled; AutomaticRecoveryEnabled=$automaticRecoveryEnabled })
            continue
        }
        $liveController = Test-LiveTaskController -Task $task -TaskConfig $taskConfig
        if ($liveController) {
            $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='active-host'; Detail=$liveController; ConfigPath=$taskConfigPath })
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
            if ([DateTime]::UtcNow -lt $requestTime.AddSeconds([int]$taskPolicy.recoveryGraceSeconds)) {
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
                [string]$_.summary -like "Orchestrator continuation scheduled '*' after '$completedAgentId'."
            } | Sort-Object timestampUtc -Descending | Select-Object -First 1)
            $taskStatus = [string]$task.status
            if ($taskStatus -in @($taskPolicy.stopStatuses)) {
                if ($Repair) {
                    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Continuation request stopped at durable task gate '$taskStatus'." -Evidence @("continuation-event:$requestId", "result:gate:$taskStatus") -ConfigPath $taskConfigPath -CodexHome $CodexHome | Out-Null
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
                        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Continuation reached successful '$nextAgentId' outcome." -Evidence @("continuation-event:$requestId", "result:completed:$nextAgentId") -ConfigPath $taskConfigPath -CodexHome $CodexHome | Out-Null
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
                $parameters = @{ Mode=[string]$task.mode; TaskSelector=[string]$task.selector; TaskId=[string]$task.taskId; RepositoryIds=@($repositoryIds); UserInstruction="Durable continuation recovery after '$completedAgentId'. Run only '$nextAgentId' and preserve every gate and completed artifact."; Resume=$true; TargetAgentId=$nextAgentId; ConfigPath=$taskConfigPath; CodexHome=$CodexHome }
                if ($ElevatedApproved -or [bool]$taskPolicy.useElevatedExecution) { $parameters.ElevatedApproved=$true }
                $runResult = & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @parameters
                & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor ecosystem -Type continuation-reconciled -Summary "Recovered scheduled continuation to '$nextAgentId'." -Evidence @("continuation-event:$requestId", "result:restarted:$nextAgentId") -ConfigPath $taskConfigPath -CodexHome $CodexHome | Out-Null
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='restarted'; RequestId=$requestId; CompletedAgentId=$completedAgentId; NextAgentId=$nextAgentId; Result=$runResult })
                continue
            }

            if (-not $Repair) {
                $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='continuation-required'; RequestId=$requestId; CompletedAgentId=$completedAgentId; ConfigPath=$taskConfigPath })
                continue
            }
            $continueParameters = @{ TaskId=[string]$task.taskId; CompletedAgentId=$completedAgentId; ConfigPath=$taskConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved -or [bool]$taskPolicy.useElevatedExecution) { $continueParameters.ElevatedApproved=$true }
            $continuationResult = & (Join-Path $PSScriptRoot 'Invoke-OrchestratorContinuation.ps1') @continueParameters
            & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$task.taskId) -Actor orchestrator -Type continuation-reconciled -Summary "Orchestrator reconciled missing continuation after '$completedAgentId' with result '$([string]$continuationResult.Status)'." -Evidence @("continuation-event:$requestId", "result:$([string]$continuationResult.Status)") -ConfigPath $taskConfigPath -CodexHome $CodexHome | Out-Null
            $items.Add([pscustomobject]@{ TaskId=[string]$task.taskId; Status='reconciled'; RequestId=$requestId; CompletedAgentId=$completedAgentId; Result=$continuationResult })
        }
    }
}
finally { $lock.Dispose() }

[pscustomobject]@{ Status='completed'; Items=@($items) }
