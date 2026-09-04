[CmdletBinding()]
param(
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

$recoveredLeases = @(Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds $lockTimeoutSeconds -Action {
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
        $manifestDirectory = Join-Path $taskRoot 'workspaces'
        foreach ($manifestPath in @(Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$manifest.leaseId -ne $leaseId -or [string]$manifest.runId -ne $runId) { continue }
            $manifest | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'released' -Force
            $manifest | Add-Member -NotePropertyName releaseReason -NotePropertyValue "stale-lease-recovery:$reason" -Force
            $manifest | Add-Member -NotePropertyName releasedAtUtc -NotePropertyValue $releasedAtUtc -Force
            $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $releasedAtUtc -Force
            Write-Utf8NoBomAtomic -Path $manifestPath.FullName -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        }

        if ($task -and ([string]$task.status -notin $terminalStatuses)) {
            Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds $lockTimeoutSeconds -Action {
                $currentTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $stillOwnsRecoveredLease = $currentTask.PSObject.Properties['executionRunId'] -and $currentTask.PSObject.Properties['workspaceLeaseId'] -and [string]$currentTask.executionRunId -eq $runId -and [string]$currentTask.workspaceLeaseId -eq $leaseId
                if ($stillOwnsRecoveredLease -and ([string]$currentTask.status -notin $terminalStatuses)) {
                    $currentTask.status = 'interrupted'
                    $currentTask.currentStage = 'workspace_lease_recovered'
                    $currentTask.lastMessage = "Controller lease was recovered after '$reason'; the isolated clone was preserved for resume."
                    if ($currentTask.PSObject.Properties['workflowProcessId']) { $currentTask.PSObject.Properties.Remove('workflowProcessId') }
                    $currentTask.updatedAtUtc = $releasedAtUtc
                    Write-Utf8NoBomAtomic -Path $taskPath -Content (($currentTask | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
                }
            } | Out-Null
        }

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

foreach ($recoveredLease in $recoveredLeases) {
    $taskPath = Join-Path $stateRoot "tasks\$([string]$recoveredLease.taskId)\task.json"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { continue }
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId ([string]$recoveredLease.taskId) -Actor ecosystem -Type workflow-status -Summary "Recovered stale workspace lease; isolated clone preserved. Reason: $([string]$recoveredLease.reason)." -Artifact $coordinatorPath -Evidence @("run-id:$([string]$recoveredLease.runId)","lease-id:$([string]$recoveredLease.leaseId)") -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

return @($recoveredLeases)
