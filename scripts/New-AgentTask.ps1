[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $TaskSelector,
    [Parameter(Mandatory)][ValidateSet('manual','automate')][string] $Mode,
    [string] $TaskName,
    [string] $TaskType,
    [string] $RepositoryId,
    [string[]] $RepositoryIds = @(),
    [switch] $Resume,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$selectedRepositoryIds = [Collections.Generic.List[string]]::new()
foreach ($id in @($RepositoryIds) + @($RepositoryId)) {
    $value = [string]$id
    if ([string]::IsNullOrWhiteSpace($value) -or $selectedRepositoryIds.Contains($value)) { continue }
    if (-not @($config.repositories | Where-Object { $_.id -eq $value -and $_.enabled }).Count) { throw "Enabled repository '$value' was not found." }
    $selectedRepositoryIds.Add($value)
}
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$taskLockPath = Join-Path $taskRoot 'task-state.lock'
$mutation = Invoke-EcosystemFileLock -LockPath $taskLockPath -TimeoutSeconds 30 -Action {
    if ((Test-Path -LiteralPath $taskPath) -and -not $Resume) {
        throw "Task '$TaskId' already exists. Use -Resume to continue it."
    }
    if (-not (Test-Path -LiteralPath $taskPath)) {
        $now = [DateTime]::UtcNow.ToString('o')
        $resolvedTaskName = if (-not [string]::IsNullOrWhiteSpace($TaskName)) { $TaskName.Trim() } elseif ($TaskSelector -notmatch '^(?i:https?://|[0-9]+$)') { $TaskSelector.Trim() } else { $TaskId }
        $resolvedTaskType = if ([string]::IsNullOrWhiteSpace($TaskType)) { 'Task' } else { $TaskType.Trim() }
        $document = [ordered]@{
            taskId = $TaskId
            selector = $TaskSelector
            mode = $Mode
            taskName = $resolvedTaskName
            taskType = $resolvedTaskType
            branchName = New-TaskBranchName -TaskName $resolvedTaskName -TaskType $resolvedTaskType
            repositoryId = if ($selectedRepositoryIds.Count) { $selectedRepositoryIds[0] } else { $null }
            repositoryIds = @($selectedRepositoryIds)
            status = 'created'
            createdAtUtc = $now
            updatedAtUtc = $now
            currentStage = 'not-started'
            lastMessage = 'Task created. Workflow has not started yet.'
            revision = 1
            agentStatuses = [ordered]@{
                orchestrator = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                knowledge_keeper = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                requirements_analyst = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                developer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                reviewer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                review_verifier = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                pipeline_monitor = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
                health_check = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            }
        }
        Write-Utf8NoBomAtomic -Path $taskPath -Content (($document | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        return [pscustomobject]@{ Created=$true; ScopeChanged=$false; BranchMetadataChanged=$false; BranchName=[string]$document.branchName }
    }
    $document = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $scopeChanged = $false
    if ($selectedRepositoryIds.Count) {
        $previousIds = if ($document.PSObject.Properties['repositoryIds']) { @($document.repositoryIds) } elseif ($document.PSObject.Properties['repositoryId'] -and $document.repositoryId) { @([string]$document.repositoryId) } else { @() }
        if (($previousIds -join '|') -ne (@($selectedRepositoryIds) -join '|')) {
            $document | Add-Member -NotePropertyName repositoryId -NotePropertyValue $selectedRepositoryIds[0] -Force
            $document | Add-Member -NotePropertyName repositoryIds -NotePropertyValue @($selectedRepositoryIds) -Force
            $scopeChanged = $true
        }
    }
    $existingTaskName = if ($document.PSObject.Properties['taskName']) { [string]$document.taskName } else { '' }
    $existingTaskType = if ($document.PSObject.Properties['taskType']) { [string]$document.taskType } else { '' }
    $existingBranchName = if ($document.PSObject.Properties['branchName']) { [string]$document.branchName } else { '' }
    $resolvedTaskName = if (-not [string]::IsNullOrWhiteSpace($TaskName)) { $TaskName.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($existingTaskName)) { $existingTaskName.Trim() } elseif ($TaskSelector -notmatch '^(?i:https?://|[0-9]+$)') { $TaskSelector.Trim() } else { $TaskId }
    $resolvedTaskType = if (-not [string]::IsNullOrWhiteSpace($TaskType)) { $TaskType.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($existingTaskType)) { $existingTaskType.Trim() } else { 'Task' }
    $branchMetadataChanged = $false
    if ([string]::IsNullOrWhiteSpace($existingTaskName)) {
        $document | Add-Member -NotePropertyName taskName -NotePropertyValue $resolvedTaskName -Force
        $branchMetadataChanged = $true
    }
    if ([string]::IsNullOrWhiteSpace($existingTaskType)) {
        $document | Add-Member -NotePropertyName taskType -NotePropertyValue $resolvedTaskType -Force
        $branchMetadataChanged = $true
    }
    if ([string]::IsNullOrWhiteSpace($existingBranchName) -or -not (Test-TaskBranchName -BranchName $existingBranchName)) {
        $existingBranchName = New-TaskBranchName -TaskName $resolvedTaskName -TaskType $resolvedTaskType
        $document | Add-Member -NotePropertyName branchName -NotePropertyValue $existingBranchName -Force
        $branchMetadataChanged = $true
    }
    if ($scopeChanged -or $branchMetadataChanged) {
        $document | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-Utf8NoBomAtomic -Path $taskPath -Content (($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    }
    return [pscustomobject]@{ Created=$false; ScopeChanged=$scopeChanged; BranchMetadataChanged=$branchMetadataChanged; BranchName=$existingBranchName }
}
if ([bool]$mutation.Created) {
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'user' -Type 'task-created' -Summary "Task selected in $Mode mode for repositories $($selectedRepositoryIds -join ', '): $TaskSelector" -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
elseif ([bool]$mutation.ScopeChanged) {
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'user' -Type 'workflow-status' -Summary "Repository scope updated: $($selectedRepositoryIds -join ', ')." -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
if (-not [bool]$mutation.Created -and [bool]$mutation.BranchMetadataChanged) {
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'workflow_host' -Type 'workflow-status' -Summary "Legacy task branch metadata migrated to '$([string]$mutation.BranchName)'." -Artifact $taskPath -Evidence @('legacy-task-branch-migration') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
[pscustomobject]@{ TaskId = $TaskId; TaskRoot = $taskRoot; TaskPath = $taskPath; Resumed = [bool]$Resume; RepositoryIds=@($selectedRepositoryIds) }
