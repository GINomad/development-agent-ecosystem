[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\workspace-stability-races'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force

$runRoot = Join-Path $OutputRoot ('race-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.runtime.stateRoot = Join-Path $runRoot 'state'
    $config.workflow.workspaceScheduling.coordinatorStatePath = Join-Path $runRoot 'state\workspace-coordinator.json'
    $config.workflow.workspaceScheduling.staleLeaseGraceSeconds = 90
    $isolatedConfig = Join-Path $runRoot 'agents.json'
    Write-Utf8NoBom -Path $isolatedConfig -Content (($config | ConvertTo-Json -Depth 40) + [Environment]::NewLine)
    $stateRoot = [IO.Path]::GetFullPath([string]$config.runtime.stateRoot)
    $coordinatorPath = [IO.Path]::GetFullPath([string]$config.workflow.workspaceScheduling.coordinatorStatePath)
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Write-Utf8NoBom -Path $coordinatorPath -Content (([ordered]@{ schemaVersion='2.0.0'; leases=@(); updatedAtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json) + [Environment]::NewLine)

    function Write-SyntheticTask {
        param([string] $TaskId, [string] $RunId, [string] $LeaseId, [int] $ProcessId = 0, [string] $ProcessStart = $null)
        $taskRoot = Join-Path $stateRoot "tasks\$TaskId"; New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
        $task = [ordered]@{ taskId=$TaskId; status='running'; currentStage='synthetic'; lastMessage='synthetic'; executionRunId=$RunId; workspaceLeaseId=$LeaseId; workflowHeartbeatAtUtc=[DateTime]::UtcNow.AddMinutes(-2).ToString('o'); updatedAtUtc=[DateTime]::UtcNow.AddMinutes(-2).ToString('o'); agentStatuses=[ordered]@{} }
        if ($ProcessId -gt 0) { $task.workflowProcessId=$ProcessId; $task.workflowProcessStartedAtUtc=$ProcessStart }
        Write-Utf8NoBom -Path (Join-Path $taskRoot 'task.json') -Content (($task | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
        return (Join-Path $taskRoot 'task.json')
    }

    $deadTaskId = 'race-dead-' + [guid]::NewGuid().ToString('N')
    $deadTaskPath = Write-SyntheticTask -TaskId $deadTaskId -RunId ('d' * 32) -LeaseId ('e' * 32)
    $recovered = @(& (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -TaskId $deadTaskId -ConfigPath $isolatedConfig -CodexHome $CodexHome)
    $deadTask = Get-Content -LiteralPath $deadTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $repeat = @(& (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -TaskId $deadTaskId -ConfigPath $isolatedConfig -CodexHome $CodexHome)
    if ([string]$deadTask.status -ne 'interrupted' -or [string]$deadTask.currentStage -ne 'workspace_lease_missing' -or $repeat.Count -ne 0) { throw 'Missing-lease recovery did not atomically interrupt exactly one dead-controller task.' }

    $concurrentTaskId = 'race-concurrent-' + [guid]::NewGuid().ToString('N')
    $concurrentTaskPath = Write-SyntheticTask -TaskId $concurrentTaskId -RunId ('c' * 32) -LeaseId ('k' * 32)
    $gateName = 'dae-workspace-repair-' + [guid]::NewGuid().ToString('N')
    $gate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $gateName)
    try {
        $fixture = Join-Path $root 'tests\fixtures\Wait-And-RepairWorkspaceLease.ps1'
        $repair = Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1'
        $jobOne = Start-Job -ScriptBlock { param($f,$g,$r,$t,$c) & $f -GateName $g -RepairScript $r -TaskId $t -ConfigPath $c } -ArgumentList $fixture,$gateName,$repair,$concurrentTaskId,$isolatedConfig
        $jobTwo = Start-Job -ScriptBlock { param($f,$g,$r,$t,$c) & $f -GateName $g -RepairScript $r -TaskId $t -ConfigPath $c } -ArgumentList $fixture,$gateName,$repair,$concurrentTaskId,$isolatedConfig
        $gate.Set() | Out-Null
        Wait-Job -Job @($jobOne,$jobTwo) -Timeout 30 | Out-Null
        $jobOutput = @($jobOne,$jobTwo | ForEach-Object { Receive-Job -Job $_ -ErrorAction SilentlyContinue })
        if ($jobOne.State -ne 'Completed' -or $jobTwo.State -ne 'Completed') { throw 'Concurrent deterministic recovery jobs did not complete.' }
    }
    finally {
        if ($jobOne) { Remove-Job -Job $jobOne -Force -ErrorAction SilentlyContinue }
        if ($jobTwo) { Remove-Job -Job $jobTwo -Force -ErrorAction SilentlyContinue }
        $gate.Dispose()
    }
    $concurrentTask = Get-Content -LiteralPath $concurrentTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$concurrentTask.status -ne 'interrupted' -or [string]$concurrentTask.currentStage -ne 'workspace_lease_missing') { throw 'Concurrent recovery did not preserve a single interrupted state.' }

    $liveTaskId = 'race-live-' + [guid]::NewGuid().ToString('N')
    $liveTaskPath = Write-SyntheticTask -TaskId $liveTaskId -RunId ('l' * 32) -LeaseId ('m' * 32) -ProcessId $PID -ProcessStart ((Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o'))
    $liveRecovery = @(& (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -TaskId $liveTaskId -ConfigPath $isolatedConfig -CodexHome $CodexHome)
    $liveTask = Get-Content -LiteralPath $liveTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($liveRecovery.Count -ne 0 -or [string]$liveTask.status -ne 'running') { throw 'A stale heartbeat with a start-time-matching live controller was interrupted.' }

    $replacementTaskId = 'race-replaced-' + [guid]::NewGuid().ToString('N')
    $replacementTaskPath = Write-SyntheticTask -TaskId $replacementTaskId -RunId ('r' * 32) -LeaseId ('s' * 32)
    $replacement = Get-Content -LiteralPath $replacementTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $replacement.executionRunId = 'n' * 32; $replacement.workspaceLeaseId = 'o' * 32; $replacement.workflowHeartbeatAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-Utf8NoBom -Path $replacementTaskPath -Content (($replacement | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $replacementRecovery = @(& (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -TaskId $replacementTaskId -ConfigPath $isolatedConfig -CodexHome $CodexHome)
    $replacementAfter = Get-Content -LiteralPath $replacementTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($replacementRecovery.Count -ne 0 -or [string]$replacementAfter.status -ne 'running' -or [string]$replacementAfter.executionRunId -ne ('n' * 32) -or [string]$replacementAfter.workspaceLeaseId -ne ('o' * 32)) { throw 'Recovery did not preserve the exact replacement run/lease identity.' }

    # Simulate a stale recovery discovering an old coordinator lease after a
    # resumed run has already replaced the on-disk manifest identity. Recovery
    # may finalize the old task state, but must never release the new clone.
    $manifestTaskId = 'race-manifest-' + [guid]::NewGuid().ToString('N')
    $oldRunId = 'a' * 32; $oldLeaseId = 'b' * 32; $newRunId = 'x' * 32; $newLeaseId = 'y' * 32
    $manifestTaskPath = Write-SyntheticTask -TaskId $manifestTaskId -RunId $oldRunId -LeaseId $oldLeaseId
    $manifestDirectory = Join-Path (Split-Path -Parent $manifestTaskPath) 'workspaces'; New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $newManifest = [ordered]@{ schemaVersion='2.0.0'; taskId=$manifestTaskId; repositoryId='fixture'; clonePath=(Join-Path $runRoot 'clone-new'); lifecycle='active'; runId=$newRunId; leaseId=$newLeaseId; updatedAtUtc=[DateTime]::UtcNow.ToString('o') }
    Write-Utf8NoBom -Path (Join-Path $manifestDirectory 'fixture.json') -Content (($newManifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $oldLease = [ordered]@{ taskId=$manifestTaskId; runId=$oldRunId; leaseId=$oldLeaseId; lifecycle='active'; heartbeatAtUtc=[DateTime]::UtcNow.AddMinutes(-2).ToString('o') }
    Write-Utf8NoBom -Path $coordinatorPath -Content (([ordered]@{ schemaVersion='2.0.0'; leases=@($oldLease); updatedAtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    & (Join-Path $root 'scripts\Repair-StaleTaskWorkspaceLeases.ps1') -ConfigPath $isolatedConfig -CodexHome $CodexHome | Out-Null
    $manifestAfter = Get-Content -LiteralPath (Join-Path $manifestDirectory 'fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifestAfter.runId -ne $newRunId -or [string]$manifestAfter.leaseId -ne $newLeaseId -or [string]$manifestAfter.lifecycle -ne 'active') { throw 'Old lease recovery released a replacement workspace manifest.' }

    # Queue order is durable in coordinator state, rather than depending on a
    # task-file scan that might finish before an older resume registers itself.
    $repositoryId = [string]$config.repositories[0].id
    $olderQueueId = 'race-queued-old-' + [guid]::NewGuid().ToString('N')
    $newQueueId = 'race-queued-new-' + [guid]::NewGuid().ToString('N')
    foreach ($queuedId in @($olderQueueId,$newQueueId)) {
        $queuedRoot = Join-Path $stateRoot "tasks\$queuedId"; New-Item -ItemType Directory -Path $queuedRoot -Force | Out-Null
        $queuedCreatedAtUtc = if ($queuedId -eq $olderQueueId) { [DateTime]::UtcNow.AddMinutes(-2).ToString('o') } else { [DateTime]::UtcNow.ToString('o') }
        $queuedTask = [ordered]@{ taskId=$queuedId; status='queued'; createdAtUtc=$queuedCreatedAtUtc; repositoryIds=@($repositoryId); agentStatuses=[ordered]@{} }
        Write-Utf8NoBom -Path (Join-Path $queuedRoot 'task.json') -Content (($queuedTask | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    }
    $queueEntry = [ordered]@{ taskId=$olderQueueId; runId=('q' * 32); createdAtUtc=[DateTime]::UtcNow.AddMinutes(-2).ToString('o'); queuedAtUtc=[DateTime]::UtcNow.ToString('o') }
    Write-Utf8NoBom -Path $coordinatorPath -Content (([ordered]@{ schemaVersion='2.0.0'; leases=@(); queuedTasks=@($queueEntry); updatedAtUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    $queueOutcome = & (Join-Path $root 'scripts\Switch-TaskWorkspace.ps1') -TaskId $newQueueId -RunId ('z' * 32) -PrepareOnly -ConfigPath $isolatedConfig -CodexHome $CodexHome
    if ([string]$queueOutcome.Status -ne 'would-queue') { throw 'A durable older queue registration was bypassed by a later workspace admission.' }

    [pscustomobject]@{ Passed=$true; Checks=@('dead-controller-missing-lease-once','deterministic-concurrent-recovery','live-controller-preserved','replacement-identity-preserved','replacement-manifest-preserved','durable-fifo-registration'); OutputRoot=$runRoot }
}
finally {
    # The caller's output root retains artifacts for diagnosis; cleanup is handled by normal retention.
}
