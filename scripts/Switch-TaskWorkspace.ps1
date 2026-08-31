[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $RunId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $ExpectedLeaseId,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$repositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds | ForEach-Object { [string]$_ }) } elseif ($task.repositoryId) { @([string]$task.repositoryId) } else { @() })
if (-not $repositoryIds.Count) { throw "Task '$TaskId' has no repository workspace." }
if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N') }
$workspaceRoot = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.workspaceRoot) -Config $config -CodexHome $CodexHome
$plannedWorkspaces = @($repositoryIds | ForEach-Object {
    $requestedRepositoryId = [string]$_
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $requestedRepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$requestedRepositoryId' was not found." }
    $layout = Get-TaskWorkspaceLayout -WorkspaceRoot $workspaceRoot -TaskId $TaskId -RepositoryId $requestedRepositoryId -RunId $RunId
    [pscustomobject][ordered]@{ RepositoryId=$requestedRepositoryId; Path=[string]$layout.ClonePath; Branch=[string]$layout.Branch; BaseSha=$null; Lifecycle='planned'; CanonicalOrigin=[string]$repository.url; RunId=$RunId; LeaseId=$null; ManifestPath=(Join-Path $taskRoot "workspaces\$requestedRepositoryId.json") }
})
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$controllerProcess = Get-Process -Id $PID -ErrorAction Stop
$controllerStartedAtUtc = $controllerProcess.StartTime.ToUniversalTime().ToString('o')
if (-not $PrepareOnly) {
    & (Join-Path $PSScriptRoot 'Repair-StaleTaskWorkspaceLeases.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
function Get-QueuePosition {
    $items = [Collections.Generic.List[object]]::new()
    $leasedTaskIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) {
        try {
            $queueCoordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($lease in @($queueCoordinator.leases)) { $null = $leasedTaskIds.Add([string]$lease.taskId) }
        }
        catch { }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter task.json -File -Recurse -ErrorAction SilentlyContinue)) {
        try { $candidate = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (([string]$candidate.taskId -eq $TaskId -or [string]$candidate.status -eq 'queued') -and -not $leasedTaskIds.Contains([string]$candidate.taskId)) { $items.Add($candidate) }
    }
    $ordered = @($items | Sort-Object @{Expression={ try { [DateTime]::Parse([string]$_.createdAtUtc).ToUniversalTime() } catch { [DateTime]::MaxValue } }}, @{Expression={[string]$_.taskId}})
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        if ([string]$ordered[$index].taskId -eq $TaskId) { return ($index + 1) }
    }
    return $null
}
function Set-TaskQueued {
    Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        $current = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $current.status = 'queued'; $current.currentStage = 'workspace_queued'; $current.lastMessage = 'Task queued awaiting an independent workspace lease.'; $current.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-Utf8NoBomAtomic -Path $taskPath -Content (($current | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
    } | Out-Null
}
function Set-TaskWorkspaceActive {
    param([Parameter(Mandatory)][string] $LeaseId)
    Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        $current = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $now = [DateTime]::UtcNow.ToString('o')
        $current | Add-Member -NotePropertyName status -NotePropertyValue 'running' -Force
        $current | Add-Member -NotePropertyName currentStage -NotePropertyValue 'workspace_active' -Force
        $current | Add-Member -NotePropertyName lastMessage -NotePropertyValue 'Independent task workspace lease is active.' -Force
        $current | Add-Member -NotePropertyName executionRunId -NotePropertyValue $RunId -Force
        $current | Add-Member -NotePropertyName workspaceLeaseId -NotePropertyValue $LeaseId -Force
        $current | Add-Member -NotePropertyName workflowHeartbeatAtUtc -NotePropertyValue $now -Force
        $current | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force
        Write-Utf8NoBomAtomic -Path $taskPath -Content (($current | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
    } | Out-Null
}
$admission = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject][ordered]@{ schemaVersion='2.0.0'; leases=@(); updatedAtUtc=$null } }
    if (-not $coordinator.PSObject.Properties['leases']) { $coordinator | Add-Member -NotePropertyName leases -NotePropertyValue @() -Force }
    $existing = $coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId } | Select-Object -First 1
    $capacity = [int]$config.workflow.workspaceScheduling.maxActiveTasks
    if ($null -ne $existing) {
        if (-not $ExpectedLeaseId) { throw "Task '$TaskId' already has an active controller." }
        if ([string]$existing.leaseId -ne $ExpectedLeaseId -or [string]$existing.runId -ne $RunId) { throw "Task '$TaskId' active lease does not match the requested run." }
        return [pscustomobject]@{ Status='already-active'; Lease=$existing; Capacity=$capacity; ActiveTaskCount=@($coordinator.leases).Count }
    }
    if ($ExpectedLeaseId) { throw "Expected lease '$ExpectedLeaseId' for task '$TaskId' is no longer active." }
    $activeCount = @($coordinator.leases).Count
    $leasedTaskIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($lease in @($coordinator.leases)) { $null = $leasedTaskIds.Add([string]$lease.taskId) }
    $waitingTasks = [Collections.Generic.List[object]]::new()
    foreach ($taskFile in @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter task.json -File -Recurse -ErrorAction SilentlyContinue)) {
        try { $waitingTask = Get-Content -LiteralPath $taskFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([string]$waitingTask.status -eq 'queued' -and -not $leasedTaskIds.Contains([string]$waitingTask.taskId)) { $waitingTasks.Add($waitingTask) }
    }
    $firstWaitingTask = @($waitingTasks | Sort-Object @{Expression={ try { [DateTime]::Parse([string]$_.createdAtUtc).ToUniversalTime() } catch { [DateTime]::MaxValue } }}, @{Expression={[string]$_.taskId}} | Select-Object -First 1)
    if ($firstWaitingTask.Count -and [string]$firstWaitingTask[0].taskId -ne $TaskId) { return [pscustomobject]@{ Status='queue'; Capacity=$capacity; ActiveTaskCount=$activeCount } }
    if ($activeCount -ge $capacity) { return [pscustomobject]@{ Status='queue'; Capacity=$capacity; ActiveTaskCount=$activeCount } }
    $leaseId = [guid]::NewGuid().ToString('N')
    $lease = [pscustomobject][ordered]@{ taskId=$TaskId; runId=$RunId; leaseId=$leaseId; lifecycle='provisioning'; acquiredAtUtc=[DateTime]::UtcNow.ToString('o'); heartbeatAtUtc=[DateTime]::UtcNow.ToString('o'); controllerProcessId=$PID; controllerStartedAtUtc=$controllerStartedAtUtc; repositories=@($repositoryIds) }
    $coordinator.leases = @($coordinator.leases) + @($lease); $coordinator.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    if (-not $PrepareOnly) { Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine) }
    return [pscustomobject]@{ Status=if($PrepareOnly){'would-admit'}else{'admitted'}; Lease=$lease; Capacity=$capacity; ActiveTaskCount=($activeCount+1) }
}
if ($admission.Status -eq 'queue') {
    $queuePosition = Get-QueuePosition
    if (-not $PrepareOnly) { Set-TaskQueued }
    return [pscustomobject]@{ Status=if($PrepareOnly){'would-queue'}else{'queued'}; TaskId=$TaskId; RunId=$RunId; LeaseId=$null; Capacity=$admission.Capacity; ActiveTaskCount=$admission.ActiveTaskCount; QueuePosition=$queuePosition; Workspaces=$plannedWorkspaces }
}
if ($admission.Status -eq 'already-active') {
    $workspaces = & (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
    return [pscustomobject]@{ Status='already-active'; TaskId=$TaskId; RunId=[string]$admission.Lease.runId; LeaseId=[string]$admission.Lease.leaseId; Capacity=$admission.Capacity; ActiveTaskCount=$admission.ActiveTaskCount; QueuePosition=$null; Workspaces=@($workspaces) }
}
if ($PrepareOnly) { return [pscustomobject]@{ Status='would-admit'; TaskId=$TaskId; RunId=$RunId; LeaseId=[string]$admission.Lease.leaseId; Capacity=$admission.Capacity; ActiveTaskCount=$admission.ActiveTaskCount; QueuePosition=$null; Workspaces=$plannedWorkspaces } }
try {
    $workspaces = @(& (Join-Path $PSScriptRoot 'Provision-TaskWorkspace.ps1') -TaskId $TaskId -RepositoryIds $repositoryIds -RunId $RunId -LeaseId ([string]$admission.Lease.leaseId) -ConfigPath $ConfigPath -CodexHome $CodexHome)
    Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lease = $coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId -and [string]$_.leaseId -eq [string]$admission.Lease.leaseId } | Select-Object -First 1
        if ($null -eq $lease) { throw "Workspace lease for '$TaskId' was released during provisioning." }
        $lease.lifecycle = 'active'; $lease.heartbeatAtUtc = [DateTime]::UtcNow.ToString('o'); $coordinator.updatedAtUtc = $lease.heartbeatAtUtc
        Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    } | Out-Null
    foreach ($workspace in $workspaces) {
        $manifest = Get-Content -LiteralPath $workspace.ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $manifest.lifecycle = 'active'; $manifest.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-Utf8NoBomAtomic -Path $workspace.ManifestPath -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        $workspace.Lifecycle = 'active'
    }
    Set-TaskWorkspaceActive -LeaseId ([string]$admission.Lease.leaseId)
    return [pscustomobject]@{ Status='active'; TaskId=$TaskId; RunId=$RunId; LeaseId=[string]$admission.Lease.leaseId; Capacity=$admission.Capacity; ActiveTaskCount=$admission.ActiveTaskCount; QueuePosition=$null; Workspaces=@($workspaces) }
}
catch {
    try { & (Join-Path $PSScriptRoot 'Release-TaskWorkspaceLease.ps1') -TaskId $TaskId -LeaseId ([string]$admission.Lease.leaseId) -Reason 'provisioning-failed' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null } catch { }
    throw
}
