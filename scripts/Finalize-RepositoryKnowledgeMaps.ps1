[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function Get-KnowledgeAuditIdentityKey {
    param([Parameter(Mandatory)] $Identity)
    $bindingKeys = @($Identity.sourceBindings | ForEach-Object {
        "$( [string]$_.knowledgeId)|$( [string]$_.repositoryId)|$( [string]$_.path)|$( [string]$_.revision)"
    } | Sort-Object)
    ([ordered]@{
        taskId = [string]$Identity.taskId
        taskIds = @($Identity.taskIds | ForEach-Object { [string]$_ })
        repositoryRevision = [string]$Identity.repositoryRevision
        entryIds = @($Identity.entryIds | ForEach-Object { [string]$_ })
        sourceBindings = $bindingKeys
    } | ConvertTo-Json -Depth 12 -Compress)
}

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$knowledgePath = Join-Path $taskRoot 'knowledge-update.json'
$summaryPath = Join-Path $taskRoot 'task-summary.json'

foreach ($requiredPath in @($taskPath, $knowledgePath, $summaryPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Knowledge Keeper publication artifact is missing: $requiredPath"
    }
}

$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$knowledge = Get-Content -LiteralPath $knowledgePath -Raw -Encoding UTF8 | ConvertFrom-Json
$summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$knowledge.taskId -ne $TaskId -or [string]$summary.taskId -ne $TaskId) {
    throw "Knowledge artifacts do not belong to task '$TaskId'."
}
if ([string]$summary.status -ne 'completed') {
    throw 'Repository knowledge maps can only be finalized for a completed task summary.'
}

$eligibleEntries = @($knowledge.entries | Where-Object { [string]$_.status -in @('verified', 'superseded') })
$workspaceManifestRoot = Join-Path $taskRoot 'workspaces'
if (-not (Test-Path -LiteralPath $workspaceManifestRoot -PathType Container)) {
    # Knowledge-only synthetic or legacy tasks may have no isolated checkout.
    # There is no safe repository source to map in that case; leave the task
    # publication valid and expose the omission through the returned result.
    $repositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds | ForEach-Object { [string]$_ }) } elseif ($task.PSObject.Properties['repositoryId']) { @([string]$task.repositoryId) } else { @() }
    foreach ($repositoryId in $repositoryIds) {
        & (Join-Path $PSScriptRoot 'Write-KnowledgeAccessMetric.ps1') `
            -TaskRoot $taskRoot -TaskId $TaskId -AgentId knowledge_keeper `
            -SourceKind repository-map -AccessMode fallback -SourceId $repositoryId -RepositoryId $repositoryId `
            -EvidenceKind observed -Status skipped `
            -Detail 'Repository map finalization was skipped because this legacy task has no isolated task workspace.' | Out-Null
    }
    return [pscustomobject]@{ TaskId = $TaskId; RepositoryMaps = @(); Skipped = $true; Reason = 'task-workspaces-unavailable' }
}
$taskWorkspaces = @(& (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -AllowReleased -ConfigPath $ConfigPath -CodexHome $CodexHome)
if (-not $taskWorkspaces.Count) { throw "Task '$TaskId' has no task workspaces for repository map finalization." }

$repositoryMapRoot = Join-Path $stateRoot 'repository-maps'
if (-not (Test-Path -LiteralPath $repositoryMapRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $repositoryMapRoot -Force | Out-Null
}

$results = [Collections.Generic.List[object]]::new()
foreach ($taskWorkspace in $taskWorkspaces) {
    $repositoryId = [string]$taskWorkspace.RepositoryId
    $workspacePath = [string]$taskWorkspace.Path
    $mapResult = & (Join-Path $PSScriptRoot 'Update-RepositoryKnowledgeMap.ps1') -RepositoryId $repositoryId -Workspace $workspacePath -OutputRoot $repositoryMapRoot
    $mapPath = [string]$mapResult.MapPath
    $map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $bindings = [Collections.Generic.List[object]]::new()
    $entryIds = [Collections.Generic.List[string]]::new()
    foreach ($entry in $eligibleEntries) {
        if (-not $entry.PSObject.Properties['sourceBindings']) { continue }
        foreach ($binding in @($entry.sourceBindings | Where-Object { [string]$_.repositoryId -eq $repositoryId })) {
            if (-not $entryIds.Contains([string]$entry.id)) { $entryIds.Add([string]$entry.id) }
            $bindings.Add([ordered]@{
                knowledgeId = [string]$entry.id
                repositoryId = [string]$binding.repositoryId
                path = [string]$binding.path
                revision = [string]$binding.revision
            })
        }
    }

    $mapLock = $null
    try {
        $mapLock = [IO.File]::Open(($mapPath + '.knowledge.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        # Reload under the lock so concurrent final publications cannot overwrite
        # a newer semantic audit with an older task's copy.
        $map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingKnowledgeAudit = if ($map.audit.PSObject.Properties['knowledgeAudit']) { $map.audit.knowledgeAudit } else { $null }
        $existingEntryIds = if ($existingKnowledgeAudit) { @($existingKnowledgeAudit.entryIds | ForEach-Object { [string]$_ }) } else { @() }
        $existingTaskIds = if ($existingKnowledgeAudit -and $existingKnowledgeAudit.PSObject.Properties['taskIds']) {
            @($existingKnowledgeAudit.taskIds | ForEach-Object { [string]$_ })
        }
        elseif ($existingKnowledgeAudit -and $existingKnowledgeAudit.PSObject.Properties['taskId']) {
            @([string]$existingKnowledgeAudit.taskId)
        }
        else { @() }
        $existingBindings = if ($existingKnowledgeAudit) {
            @($existingKnowledgeAudit.sourceBindings | ForEach-Object {
                [ordered]@{
                    knowledgeId = [string]$_.knowledgeId
                    repositoryId = [string]$_.repositoryId
                    path = [string]$_.path
                    revision = [string]$_.revision
                }
            })
        }
        else { @() }
        $mergedEntryIds = [Collections.Generic.List[string]]::new()
        foreach ($value in @($existingEntryIds)) {
            if ($value -and -not $mergedEntryIds.Contains([string]$value)) { $mergedEntryIds.Add([string]$value) }
        }
        foreach ($value in $entryIds) {
            if ($value -and -not $mergedEntryIds.Contains([string]$value)) { $mergedEntryIds.Add([string]$value) }
        }
        $mergedTaskIds = [Collections.Generic.List[string]]::new()
        foreach ($value in @($existingTaskIds) + @($TaskId)) {
            if ($value -and -not $mergedTaskIds.Contains([string]$value)) { $mergedTaskIds.Add([string]$value) }
        }
        $mergedBindings = [Collections.Generic.List[object]]::new()
        $bindingKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($binding in @($existingBindings)) {
            $key = "$( [string]$binding.knowledgeId)|$( [string]$binding.repositoryId)|$( [string]$binding.path)|$( [string]$binding.revision)"
            if ($bindingKeys.Add($key)) { $mergedBindings.Add($binding) }
        }
        foreach ($binding in $bindings) {
            $key = "$( [string]$binding.knowledgeId)|$( [string]$binding.repositoryId)|$( [string]$binding.path)|$( [string]$binding.revision)"
            if ($bindingKeys.Add($key)) { $mergedBindings.Add($binding) }
        }
        $knowledgeAuditIdentity = [ordered]@{
            taskId = $TaskId
            taskIds = $mergedTaskIds.ToArray()
            repositoryRevision = [string]$map.revision
            entryIds = $mergedEntryIds.ToArray()
            sourceBindings = $mergedBindings.ToArray()
        }
        $existingIdentity = if ($existingKnowledgeAudit) {
            [ordered]@{
                taskId = [string]$existingKnowledgeAudit.taskId
                taskIds = if ($existingKnowledgeAudit.PSObject.Properties['taskIds']) { @($existingKnowledgeAudit.taskIds | ForEach-Object { [string]$_ }) } else { @([string]$existingKnowledgeAudit.taskId) }
                repositoryRevision = [string]$existingKnowledgeAudit.repositoryRevision
                entryIds = @($existingKnowledgeAudit.entryIds | ForEach-Object { [string]$_ })
                sourceBindings = @($existingBindings)
            }
        }
        $identityChanged = -not $existingIdentity -or
            (Get-KnowledgeAuditIdentityKey -Identity $existingIdentity) -ne
            (Get-KnowledgeAuditIdentityKey -Identity $knowledgeAuditIdentity)
        if ($identityChanged -or [string]$map.audit.semanticStatus -ne 'verified') {
            $knowledgeAudit = [ordered]@{ updatedAtUtc = [DateTime]::UtcNow.ToString('o') }
            foreach ($propertyName in $knowledgeAuditIdentity.Keys) {
                $knowledgeAudit[$propertyName] = $knowledgeAuditIdentity[$propertyName]
            }
            $map.audit.semanticStatus = 'verified'
            $map.audit | Add-Member -NotePropertyName knowledgeAudit -NotePropertyValue $knowledgeAudit -Force
            Write-Utf8NoBomAtomic -Path $mapPath -Content (($map | ConvertTo-Json -Depth 24) + [Environment]::NewLine)
        }
    }
    finally {
        if ($mapLock) { $mapLock.Dispose() }
    }

    $map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mapSha = Get-EcosystemFileSha256 -Path $mapPath
    $runId = if ($task.PSObject.Properties['executionRunId']) { [string]$task.executionRunId } else { '' }
    $leaseId = if ($task.PSObject.Properties['workspaceLeaseId']) { [string]$task.workspaceLeaseId } else { '' }
    & (Join-Path $PSScriptRoot 'Write-KnowledgeAccessMetric.ps1') `
        -TaskRoot $taskRoot -TaskId $TaskId -RunId $runId -LeaseId $leaseId -AgentId knowledge_keeper `
        -SourceKind repository-map -AccessMode used -SourceId $repositoryId -SourceLocation $mapPath `
        -SourceRevision ([string]$map.sourceFingerprint) -RepositoryId $repositoryId `
        -CacheHit:([bool]$mapResult.Reused) -EvidenceKind verified `
        -Detail "Final Knowledge Keeper publication marked the repository map semantic audit verified with $(@($entryIds).Count) durable knowledge reference(s)." | Out-Null

    $results.Add([pscustomobject][ordered]@{
        RepositoryId = $repositoryId
        MapPath = $mapPath
        MapSha256 = $mapSha
        Revision = [string]$map.revision
        SourceFingerprint = [string]$map.sourceFingerprint
        SemanticStatus = [string]$map.audit.semanticStatus
        KnowledgeEntryIds = @($entryIds)
        Reused = [bool]$mapResult.Reused
    })
}

[pscustomobject]@{
    TaskId = $TaskId
    RepositoryMaps = @($results)
}
