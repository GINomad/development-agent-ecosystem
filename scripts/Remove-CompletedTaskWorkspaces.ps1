[CmdletBinding(SupportsShouldProcess)]
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
$workspaceRoot = [IO.Path]::GetFullPath((Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.workspaceRoot) -Config $config -CodexHome $CodexHome)).TrimEnd([char[]]@('\','/'))
$workspacePrefix = $workspaceRoot + [IO.Path]::DirectorySeparatorChar
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$tasksRoot = Join-Path $stateRoot 'tasks'
$taskPaths = if ($TaskId) {
    @(Join-Path $tasksRoot "$TaskId\task.json")
}
else {
    @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'task.json' })
}
$results = [Collections.Generic.List[object]]::new()

function Resolve-SafeCleanupPath {
    param([Parameter(Mandatory)][string] $ClonePath)

    $resolvedClonePath = [IO.Path]::GetFullPath($ClonePath).TrimEnd([char[]]@('\','/'))
    if ($resolvedClonePath -eq $workspaceRoot -or -not $resolvedClonePath.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove workspace outside '$workspaceRoot': $resolvedClonePath"
    }

    if (Test-Path -LiteralPath $resolvedClonePath) {
        $relativePath = $resolvedClonePath.Substring($workspacePrefix.Length)
        $currentPath = $workspaceRoot
        foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { $_ })) {
            $currentPath = Join-Path $currentPath $segment
            if (-not (Test-Path -LiteralPath $currentPath)) { break }
            $item = Get-Item -LiteralPath $currentPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to remove a workspace through a reparse point: $currentPath"
            }
        }
    }
    return $resolvedClonePath
}

function Remove-WorkspaceDirectoryWithRetry {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 10)][int] $MaximumAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq $MaximumAttempts) { throw }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}

function Get-WorkspaceCleanupPlan {
    param(
        [Parameter(Mandatory)][string] $CandidateTaskId,
        [Parameter(Mandatory)][string] $CandidateTaskPath
    )

    $task = Get-Content -LiteralPath $CandidateTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $finalClosure = [string]$task.status -eq 'completed' -and $task.PSObject.Properties['closure'] -and [string]$task.closure.status -eq 'completed'
    if (-not $finalClosure) { return [pscustomobject]@{ TaskId=$CandidateTaskId; Status='retained'; Targets=@(); Entries=@(); Reason='task-not-finally-closed' } }

    $summaryPath = Join-Path (Split-Path -Parent $CandidateTaskPath) 'task-summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return [pscustomobject]@{ TaskId=$CandidateTaskId; Status='retained'; Targets=@(); Entries=@(); Reason='task-summary-missing' } }
    $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$summary.taskId -ne $CandidateTaskId -or [string]$summary.status -ne 'completed') { return [pscustomobject]@{ TaskId=$CandidateTaskId; Status='retained'; Targets=@(); Entries=@(); Reason='task-summary-not-completed' } }

    $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ leases=@() } }
    if (@($coordinator.leases | Where-Object { [string]$_.taskId -eq $CandidateTaskId }).Count) { return [pscustomobject]@{ TaskId=$CandidateTaskId; Status='retained'; Targets=@(); Entries=@(); Reason='active-workspace-lease' } }

    $entries = [Collections.Generic.List[object]]::new()
    $targets = [Collections.Generic.List[string]]::new()
    $manifestRoot = Join-Path (Split-Path -Parent $CandidateTaskPath) 'workspaces'
    foreach ($manifestPath in @(Get-ChildItem -LiteralPath $manifestRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.taskId -ne $CandidateTaskId) { throw "Workspace manifest task mismatch: $($manifestPath.FullName)" }
        if ([string]$manifest.lifecycle -eq 'cleaned') { continue }
        if ([string]$manifest.lifecycle -ne 'released') { return [pscustomobject]@{ TaskId=$CandidateTaskId; Status='retained'; Targets=@(); Entries=@(); Reason="workspace-not-released:$([string]$manifest.repositoryId)" } }
        $clonePath = Resolve-SafeCleanupPath -ClonePath ([string]$manifest.clonePath)
        $entries.Add([pscustomobject]@{
            ManifestPath = $manifestPath.FullName
            ManifestSha256 = Get-EcosystemFileSha256 -Path $manifestPath.FullName
            Document = $manifest
            ClonePath = $clonePath
            RepositoryId = [string]$manifest.repositoryId
        })
        $targets.Add($clonePath)
    }
    return [pscustomobject]@{
        TaskId = $CandidateTaskId
        Status = 'eligible'
        TaskSha256 = Get-EcosystemFileSha256 -Path $CandidateTaskPath
        SummarySha256 = Get-EcosystemFileSha256 -Path $summaryPath
        Targets = @($targets)
        Entries = @($entries)
        Reason = 'task-finally-closed'
    }
}

function Test-WorkspaceCleanupPlanMatches {
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual
    )

    if ([string]$Actual.Status -ne 'eligible' -or
        [string]$Actual.TaskSha256 -ne [string]$Expected.TaskSha256 -or
        [string]$Actual.SummarySha256 -ne [string]$Expected.SummarySha256 -or
        @($Expected.Entries).Count -ne @($Actual.Entries).Count) { return $false }
    foreach ($expectedEntry in @($Expected.Entries)) {
        $actualEntry = @($Actual.Entries | Where-Object { [string]$_.ManifestPath -eq [string]$expectedEntry.ManifestPath } | Select-Object -First 1)
        if (-not $actualEntry.Count -or
            [string]$actualEntry[0].ManifestSha256 -ne [string]$expectedEntry.ManifestSha256 -or
            [string]$actualEntry[0].ClonePath -ne [string]$expectedEntry.ClonePath -or
            [string]$actualEntry[0].RepositoryId -ne [string]$expectedEntry.RepositoryId) {
            return $false
        }
    }
    return $true
}

foreach ($taskPath in $taskPaths) {
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        if ($TaskId) { throw "Task '$TaskId' was not found." }
        continue
    }
    $candidateTaskId = Split-Path -Leaf (Split-Path -Parent $taskPath)
    $plan = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        Get-WorkspaceCleanupPlan -CandidateTaskId $candidateTaskId -CandidateTaskPath $taskPath
    }
    if ([string]$plan.Status -ne 'eligible') {
        $results.Add([pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason=[string]$plan.Reason })
        continue
    }
    if ($WhatIfPreference) {
        $results.Add([pscustomobject]@{ TaskId=$candidateTaskId; Status='planned'; Targets=@($plan.Targets); Removed=@(); Reason='task-finally-closed' })
        continue
    }
    if (@($plan.Entries).Count -gt 0) {
        $snapshotParameters = @{ TaskId=$candidateTaskId; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
        $snapshot = & (Join-Path $PSScriptRoot 'Save-TaskDiffSnapshot.ps1') @snapshotParameters
        if (-not $snapshot -or -not (Test-Path -LiteralPath ([string]$snapshot.SnapshotPath) -PathType Leaf)) {
            throw "Refusing to clean task '$candidateTaskId' before its dashboard diff snapshot is durable."
        }
    }
    $result = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        $revalidatedPlan = Get-WorkspaceCleanupPlan -CandidateTaskId $candidateTaskId -CandidateTaskPath $taskPath
        if (-not (Test-WorkspaceCleanupPlanMatches -Expected $plan -Actual $revalidatedPlan)) {
            return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason='cleanup-plan-changed' }
        }
        $removed = [Collections.Generic.List[string]]::new()
        foreach ($entry in @($revalidatedPlan.Entries)) {
            if ($PSCmdlet.ShouldProcess([string]$entry.ClonePath, "Remove finally closed task workspace '$candidateTaskId'")) {
                Remove-WorkspaceDirectoryWithRetry -Path ([string]$entry.ClonePath)
                $cleanedAtUtc = [DateTime]::UtcNow.ToString('o')
                $entry.Document | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'cleaned' -Force
                $entry.Document | Add-Member -NotePropertyName cleanupReason -NotePropertyValue 'task-finally-closed' -Force
                $entry.Document | Add-Member -NotePropertyName cleanedAtUtc -NotePropertyValue $cleanedAtUtc -Force
                $entry.Document | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $cleanedAtUtc -Force
                Write-Utf8NoBomAtomic -Path ([string]$entry.ManifestPath) -Content (($entry.Document | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
                $removed.Add([string]$entry.ClonePath)
            }
        }
        [pscustomobject]@{ TaskId=$candidateTaskId; Status='cleaned'; Targets=@($revalidatedPlan.Targets); Removed=@($removed); Reason='task-finally-closed' }
    }
    $results.Add($result)
}
return @($results)
