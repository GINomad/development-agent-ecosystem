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

foreach ($taskPath in $taskPaths) {
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        if ($TaskId) { throw "Task '$TaskId' was not found." }
        continue
    }
    $candidateTaskId = Split-Path -Leaf (Split-Path -Parent $taskPath)
    $result = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
        $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $finalClosure = [string]$task.status -eq 'completed' -and $task.PSObject.Properties['closure'] -and [string]$task.closure.status -eq 'completed'
        if (-not $finalClosure) { return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason='task-not-finally-closed' } }

        $summaryPath = Join-Path (Split-Path -Parent $taskPath) 'task-summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason='task-summary-missing' } }
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$summary.taskId -ne $candidateTaskId -or [string]$summary.status -ne 'completed') { return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason='task-summary-not-completed' } }

        $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ leases=@() } }
        if (@($coordinator.leases | Where-Object { [string]$_.taskId -eq $candidateTaskId }).Count) { return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason='active-workspace-lease' } }

        $manifests = [Collections.Generic.List[object]]::new()
        $targets = [Collections.Generic.List[string]]::new()
        $manifestRoot = Join-Path (Split-Path -Parent $taskPath) 'workspaces'
        foreach ($manifestPath in @(Get-ChildItem -LiteralPath $manifestRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$manifest.taskId -ne $candidateTaskId) { throw "Workspace manifest task mismatch: $($manifestPath.FullName)" }
            if ([string]$manifest.lifecycle -eq 'cleaned') { continue }
            if ([string]$manifest.lifecycle -ne 'released') { return [pscustomobject]@{ TaskId=$candidateTaskId; Status='retained'; Targets=@(); Removed=@(); Reason="workspace-not-released:$([string]$manifest.repositoryId)" } }
            $clonePath = Resolve-SafeCleanupPath -ClonePath ([string]$manifest.clonePath)
            $manifests.Add([pscustomobject]@{ Path=$manifestPath.FullName; Document=$manifest; ClonePath=$clonePath })
            $targets.Add($clonePath)
        }

        $removed = [Collections.Generic.List[string]]::new()
        foreach ($entry in $manifests) {
            if ($PSCmdlet.ShouldProcess([string]$entry.ClonePath, "Remove finally closed task workspace '$candidateTaskId'")) {
                Remove-WorkspaceDirectoryWithRetry -Path ([string]$entry.ClonePath)
                $cleanedAtUtc = [DateTime]::UtcNow.ToString('o')
                $entry.Document | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'cleaned' -Force
                $entry.Document | Add-Member -NotePropertyName cleanupReason -NotePropertyValue 'task-finally-closed' -Force
                $entry.Document | Add-Member -NotePropertyName cleanedAtUtc -NotePropertyValue $cleanedAtUtc -Force
                $entry.Document | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $cleanedAtUtc -Force
                Write-Utf8NoBomAtomic -Path ([string]$entry.Path) -Content (($entry.Document | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
                $removed.Add([string]$entry.ClonePath)
            }
        }
        [pscustomobject]@{ TaskId=$candidateTaskId; Status=if ($WhatIfPreference) { 'planned' } else { 'cleaned' }; Targets=@($targets); Removed=@($removed); Reason='task-finally-closed' }
    }
    $results.Add($result)
}
return @($results)