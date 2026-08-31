[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidateLength(5,2000)][string] $Reason,
    [ValidateSet('requirements_analyst','developer')][string] $ResumeFrom = 'requirements_analyst',
    [ValidateRange(1,2147483647)][int] $ExpectedRevision,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $ExpectedRunId,
    [ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $ExpectedLeaseId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$mutation = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject][ordered]@{ schemaVersion='2.0.0'; leases=@(); updatedAtUtc=$null } }
    $activeLease = @($coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId } | Select-Object -First 1)
    if ($activeLease.Count) { throw "Task '$TaskId' still has an active workspace lease. Stop or finish that controller before reopening the task." }
    Invoke-EcosystemFileLock -LockPath (Join-Path $taskRoot 'task-state.lock') -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$task.status -eq 'running') { throw 'Stop the workflow before reopening the task.' }
    $currentRevision = if ($task.PSObject.Properties['revision']) { [int]$task.revision } else { 1 }
    if ($ExpectedRevision -gt 0 -and $ExpectedRevision -ne $currentRevision) { throw 'The task revision changed before reopen. Refresh and retry.' }
    $currentRunId = if ($task.PSObject.Properties['executionRunId']) { [string]$task.executionRunId } else { '' }
    $currentLeaseId = if ($task.PSObject.Properties['workspaceLeaseId']) { [string]$task.workspaceLeaseId } else { '' }
    if ($ExpectedRunId -and $ExpectedRunId -ne $currentRunId) { throw 'The task run changed before reopen. Refresh and retry.' }
    if ($ExpectedLeaseId -and $ExpectedLeaseId -ne $currentLeaseId) { throw 'The task workspace lease changed before reopen. Refresh and retry.' }
    $archiveRoot = [IO.Path]::GetFullPath((Join-Path $taskRoot "revisions\revision-$currentRevision"))
    if (-not $archiveRoot.StartsWith([IO.Path]::GetFullPath($taskRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'Revision archive escaped the task root.' }
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $taskRoot -File | Where-Object { $_.Name -notin @('task.json','task-ledger.jsonl') -and $_.Extension -ne '.lock' })) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $archiveRoot $file.Name) -Force }
    Write-Utf8NoBom -Path (Join-Path $archiveRoot 'task.json') -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
    $now = [DateTime]::UtcNow.ToString('o')
    $resetAgentIds = if ($ResumeFrom -eq 'requirements_analyst') { @('requirements_analyst','developer','reviewer','pipeline_monitor','knowledge_keeper') } else { @('developer','reviewer','pipeline_monitor','knowledge_keeper') }
    foreach ($agentId in $resetAgentIds) {
        $task.agentStatuses | Add-Member -NotePropertyName $agentId -NotePropertyValue ([pscustomobject][ordered]@{ status='pending'; updatedAtUtc=$now; message="Task revision $($currentRevision + 1) reopened from $ResumeFrom." }) -Force
    }
    if ($task.PSObject.Properties['closure']) {
        $previousClosures = if ($task.PSObject.Properties['previousClosures']) { @($task.previousClosures) } else { @() }
        $task | Add-Member -NotePropertyName previousClosures -NotePropertyValue (@($previousClosures) + @($task.closure)) -Force
        $task.PSObject.Properties.Remove('closure')
    }
    $task | Add-Member -NotePropertyName revision -NotePropertyValue ($currentRevision + 1) -Force
    $task | Add-Member -NotePropertyName reopenedAtUtc -NotePropertyValue $now -Force
    $task | Add-Member -NotePropertyName reopenReason -NotePropertyValue $Reason.Trim() -Force
    $task | Add-Member -NotePropertyName revisionResetAgentIds -NotePropertyValue @($resetAgentIds) -Force
    $task | Add-Member -NotePropertyName status -NotePropertyValue 'interrupted' -Force
    $task | Add-Member -NotePropertyName currentStage -NotePropertyValue "reopened_from_$ResumeFrom" -Force
    $task | Add-Member -NotePropertyName lastMessage -NotePropertyValue "Task reopened as revision $($currentRevision + 1): $($Reason.Trim())" -Force
    $task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $now -Force
    Write-Utf8NoBomAtomic -Path $taskPath -Content (($task | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
    [pscustomobject]@{ Revision=$currentRevision + 1; ResetAgentIds=@($resetAgentIds); ArchiveRoot=$archiveRoot }
    }
}
$currentRevision = [int]$mutation.Revision - 1
$resetAgentIds = @($mutation.ResetAgentIds)
$archiveRoot = [string]$mutation.ArchiveRoot
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor user -Type task-reopened -Summary "Task reopened as revision $($currentRevision + 1) from '$ResumeFrom': $($Reason.Trim())" -Artifact $taskPath -Evidence @($archiveRoot) -TargetAgentId $ResumeFrom -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
& (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') -TaskId $TaskId -Text "Rework revision $($currentRevision + 1). Reason: $($Reason.Trim())" -Author user -TargetAgentId $ResumeFrom -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
[pscustomobject]@{ TaskId=$TaskId; Revision=$currentRevision + 1; ResumeFrom=$ResumeFrom; ResetAgentIds=$resetAgentIds; ArchiveRoot=$archiveRoot }
