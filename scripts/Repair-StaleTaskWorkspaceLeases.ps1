[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$lockTimeoutSeconds = [int]$config.workflow.workspaceScheduling.lockTimeoutSeconds
$staleLeaseGraceSeconds = [int]$config.workflow.workspaceScheduling.staleLeaseGraceSeconds
$now = [DateTime]::UtcNow
$terminalStatuses = @('completed','failed')
$lockMetricsPath = Join-Path $stateRoot 'health\lock-metrics.jsonl'

function ConvertTo-UtcTimestamp {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return [DateTime]::MinValue }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    $parsedAtUtc = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedAtUtc)) {
        return $parsedAtUtc.ToUniversalTime()
    }
    return [DateTime]::MinValue
}

$recoveredLeases = @(Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds $lockTimeoutSeconds -MetricsPath $lockMetricsPath -CorrelationId 'workspace-lease-repair' -Action {
    if (-not (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) { return @() }
    $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $coordinator.PSObject.Properties['leases']) { return @() }

    $kept = [Collections.Generic.List[object]]::new()
    $recovered = [Collections.Generic.List[object]]::new()
    foreach ($lease in @($coordinator.leases)) {
        $taskId = [string]$lease.taskId
        $runId = [string]$lease.runId
        $leaseId = [string]$lease.leaseId
        $taskRoot = Join-Path $stateRoot "tasks\$taskId"
        $taskPath = Join-Path $taskRoot 'task.json'
        $task = $null
        if (Test-Path -LiteralPath $taskPath -PathType Leaf) {
            try { $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { $task = $null }
        }

        $heartbeatAtUtc = [DateTime]::MinValue
        foreach ($candidate in @(
            $(if ($lease.PSObject.Properties['heartbeatAtUtc']) { $lease.heartbeatAtUtc }),
            $(if ($lease.PSObject.Properties['acquiredAtUtc']) { $lease.acquiredAtUtc })
        )) {
            $candidateAtUtc = ConvertTo-UtcTimestamp -Value $candidate
            if ($candidateAtUtc -ne [DateTime]::MinValue) {
                $heartbeatAtUtc = $candidateAtUtc
                break
            }
        }
        $leaseAgeSeconds = if ($heartbeatAtUtc -eq [DateTime]::MinValue) { [double]::PositiveInfinity } else { [Math]::Max(0, ($now - $heartbeatAtUtc).TotalSeconds) }
        $hasControllerIdentity = $lease.PSObject.Properties['controllerProcessId'] -and [int]$lease.controllerProcessId -gt 0 -and $lease.PSObject.Properties['controllerStartedAtUtc']
        $controllerIdentityAlive = $false
        if ($hasControllerIdentity) {
            try {
                $controllerProcess = Get-Process -Id ([int]$lease.controllerProcessId) -ErrorAction Stop
                $recordedStartUtc = ConvertTo-UtcTimestamp -Value $lease.controllerStartedAtUtc
                if ($recordedStartUtc -ne [DateTime]::MinValue) {
                    $controllerIdentityAlive = [Math]::Abs(($controllerProcess.StartTime.ToUniversalTime() - $recordedStartUtc).TotalSeconds) -lt 2
                }
            }
            catch { $controllerIdentityAlive = $false }
        }
        $reason = $null

        if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
            $reason = 'task-missing'
        }
        elseif ($task -and [string]$task.status -eq 'failed') {
            $reason = "task-terminal:$([string]$task.status)"
        }
        elseif ($task -and [string]$task.status -eq 'completed' -and -not $controllerIdentityAlive) {
            $reason = "task-terminal:$([string]$task.status)"
        }
        elseif ($task -and [string]$lease.lifecycle -eq 'active') {
            $taskRunMatches = $task.PSObject.Properties['executionRunId'] -and [string]$task.executionRunId -eq $runId
            $taskLeaseMatches = $task.PSObject.Properties['workspaceLeaseId'] -and [string]$task.workspaceLeaseId -eq $leaseId
            if (-not $taskRunMatches -or -not $taskLeaseMatches) { $reason = 'task-ownership-changed' }
        }

        if (-not $reason -and $leaseAgeSeconds -ge $staleLeaseGraceSeconds) {
            if ($hasControllerIdentity) {
                $reason = if ($controllerIdentityAlive) { 'heartbeat-expired' } else { 'controller-exited' }
            }
            else {
                $reason = 'legacy-heartbeat-expired'
            }
        }

        if (-not $reason) {
            $kept.Add($lease)
            continue
        }

        $releasedAtUtc = $now.ToString('o')
        $recovered.Add([pscustomobject][ordered]@{
            taskId = $taskId
            runId = $runId
            leaseId = $leaseId
            reason = $reason
            recoveredAtUtc = $releasedAtUtc
        })
    }

    if ($recovered.Count) {
        $coordinator.leases = @($kept)
        $coordinator.updatedAtUtc = $now.ToString('o')
        Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    }
    return @($recovered)
})

# The coordinator lock protects the lease set only.  Release it before touching an
# individual task or its workspace manifests: otherwise one contended task-state
# lock serializes every admission and can deadlock with normal heartbeat paths.
foreach ($recoveredLease in $recoveredLeases) {
    $recoveredTaskId = [string]$recoveredLease.taskId
    $recoveredRunId = [string]$recoveredLease.runId
    $recoveredLeaseId = [string]$recoveredLease.leaseId
    $releasedAtUtc = [string]$recoveredLease.recoveredAtUtc
    $taskRoot = Join-Path $stateRoot "tasks\\$recoveredTaskId"
    $taskPath = Join-Path $taskRoot 'task.json'

    # A manifest is scoped by immutable run/lease identities, so a resumed task
    # cannot have its newer workspace marked released by this recovery.
    $manifestDirectory = Join-Path $taskRoot 'workspaces'
    $manifestLockPath = Join-Path $taskRoot 'workspace-manifests.lock'
    foreach ($manifestPath in @(Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        Invoke-EcosystemFileLock -LockPath $manifestLockPath -TimeoutSeconds $lockTimeoutSeconds -MetricsPath $lockMetricsPath -CorrelationId ("$recoveredTaskId/$recoveredRunId/$recoveredLeaseId") -Action {
            $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$manifest.leaseId -eq $recoveredLeaseId -and [string]$manifest.runId -eq $recoveredRunId) {
                $manifest | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'released' -Force
                $manifest | Add-Member -NotePropertyName releaseReason -NotePropertyValue "stale-lease-recovery:$([string]$recoveredLease.reason)" -Force
                $manifest | Add-Member -NotePropertyName releasedAtUtc -NotePropertyValue $releasedAtUtc -Force
                $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $releasedAtUtc -Force
                Write-Utf8NoBomAtomic -Path $manifestPath.FullName -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
            }
        } | Out-Null
    }

    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { continue }
    Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds $lockTimeoutSeconds -MetricsPath $lockMetricsPath -CorrelationId ("$recoveredTaskId/$recoveredRunId/$recoveredLeaseId") -Action {
        $currentTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stillOwnsRecoveredLease = $currentTask.PSObject.Properties['executionRunId'] -and $currentTask.PSObject.Properties['workspaceLeaseId'] -and [string]$currentTask.executionRunId -eq $recoveredRunId -and [string]$currentTask.workspaceLeaseId -eq $recoveredLeaseId
        if ($stillOwnsRecoveredLease -and ([string]$currentTask.status -notin $terminalStatuses)) {
            $currentTask.status = 'interrupted'
            $currentTask.currentStage = 'workspace_lease_recovered'
            $currentTask.lastMessage = "Controller lease was recovered after '$([string]$recoveredLease.reason)'; the isolated clone was preserved for resume."
            if ($currentTask.PSObject.Properties['workflowProcessId']) { $currentTask.PSObject.Properties.Remove('workflowProcessId') }
            $currentTask.updatedAtUtc = $releasedAtUtc
            Write-Utf8NoBomAtomic -Path $taskPath -Content (($currentTask | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
        }
    } | Out-Null
}

foreach ($recoveredLease in $recoveredLeases) {
    $taskPath = Join-Path $stateRoot "tasks\$([string]$recoveredLease.taskId)\task.json"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { continue }
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$recoveredLease.taskId) -Actor ecosystem -Type workflow-status -Summary "Recovered stale workspace lease; isolated clone preserved. Reason: $([string]$recoveredLease.reason)." -Artifact $coordinatorPath -Evidence @("run-id:$([string]$recoveredLease.runId)","lease-id:$([string]$recoveredLease.leaseId)") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

# Reconcile an absent lease only when an operator or recovery coordinator names the
# exact task. This avoids a scheduled scan changing unrelated running workflows.
if ($TaskId) {
    $targetTaskPath = Join-Path $stateRoot "tasks\\$TaskId\\task.json"
    $coordinatorAfterLeaseRecovery = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ leases=@() } }
    $hasMatchingLease = @($coordinatorAfterLeaseRecovery.leases | Where-Object { [string]$_.taskId -eq $TaskId }).Count -gt 0
    if ((Test-Path -LiteralPath $targetTaskPath -PathType Leaf) -and -not $hasMatchingLease) {
        $snapshot = Get-Content -LiteralPath $targetTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $heartbeatAtUtc = ConvertTo-UtcTimestamp -Value $(if ($snapshot.PSObject.Properties['workflowHeartbeatAtUtc']) { $snapshot.workflowHeartbeatAtUtc } else { $snapshot.updatedAtUtc })
        $heartbeatExpired = $heartbeatAtUtc -eq [DateTime]::MinValue -or ($now - $heartbeatAtUtc).TotalSeconds -ge $staleLeaseGraceSeconds
        $controllerAlive = $false
        if ($snapshot.PSObject.Properties['workflowProcessId'] -and [int]$snapshot.workflowProcessId -gt 0) {
            try {
                $process = Get-Process -Id ([int]$snapshot.workflowProcessId) -ErrorAction Stop
                if ($snapshot.PSObject.Properties['workflowProcessStartedAtUtc']) {
                    $startedAtUtc = ConvertTo-UtcTimestamp -Value $snapshot.workflowProcessStartedAtUtc
                    $controllerAlive = $startedAtUtc -ne [DateTime]::MinValue -and [Math]::Abs(($process.StartTime.ToUniversalTime() - $startedAtUtc).TotalSeconds) -lt 2
                }
                else {
                    # Legacy records cannot prove PID identity, so preserving a
                    # live PID is safer than interrupting a possible controller.
                    $controllerAlive = $null -ne $process
                }
            }
            catch { $controllerAlive = $false }
        }
        if ([string]$snapshot.status -eq 'running' -and $snapshot.PSObject.Properties['executionRunId'] -and $snapshot.PSObject.Properties['workspaceLeaseId'] -and $heartbeatExpired -and -not $controllerAlive) {
            $runId = [string]$snapshot.executionRunId; $leaseId = [string]$snapshot.workspaceLeaseId
            # A newly admitted provisioning lease wins.  This short recheck is
            # intentionally outside the task lock to preserve the no-nesting
            # lock invariant.
            $stillMissingLease = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds $lockTimeoutSeconds -MetricsPath $lockMetricsPath -CorrelationId ("$TaskId/$runId/$leaseId") -Action {
                $latestCoordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ leases=@() } }
                return @($latestCoordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId }).Count -eq 0
            }
            $changed = $false
            if ($stillMissingLease) { $changed = Invoke-EcosystemFileLock -LockPath (Join-Path (Split-Path -Parent $targetTaskPath) 'task-state.lock') -TimeoutSeconds $lockTimeoutSeconds -MetricsPath $lockMetricsPath -CorrelationId ("$TaskId/$runId/$leaseId") -Action {
                $current = Get-Content -LiteralPath $targetTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$current.status -eq 'running' -and [string]$current.executionRunId -eq $runId -and [string]$current.workspaceLeaseId -eq $leaseId) {
                    $current.status = 'interrupted'; $current.currentStage = 'workspace_lease_missing'
                    $current.lastMessage = 'Controller is no longer live and no matching workspace lease exists; preserved artifacts are ready for explicit resume.'
                    if ($current.PSObject.Properties['workflowProcessId']) { $current.PSObject.Properties.Remove('workflowProcessId') }
                    $current.updatedAtUtc = $now.ToString('o')
                    Write-Utf8NoBomAtomic -Path $targetTaskPath -Content (($current | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
                    return $true
                }
                return $false
            }
            }
            if ($changed) {
                $missingLeaseRecovery = [pscustomobject]@{ taskId=$TaskId; runId=$runId; leaseId=$leaseId; reason='workspace-lease-missing-controller-not-live'; recoveredAtUtc=$now.ToString('o') }
                $recoveredLeases += $missingLeaseRecovery
                & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor ecosystem -Type workflow-status -Summary 'Recovered running task without a matching workspace lease after controller liveness check.' -Artifact $coordinatorPath -Evidence @("run-id:$runId","lease-id:$leaseId") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            }
        }
    }
}

return @($recoveredLeases)
