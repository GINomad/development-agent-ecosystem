[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.workflow.workspaceScheduling
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetRepositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) { @([string]$task.repositoryId) } else { @() }
if (-not @($targetRepositoryIds).Count) { throw "Task '$TaskId' has no repository workspace." }

$coordinatorPath = Resolve-EcosystemPath -Value ([string]$policy.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$lockPath = "$coordinatorPath.lock"
$lockStream = $null
$deadline = [DateTime]::UtcNow.AddSeconds([int]$policy.lockTimeoutSeconds)
while (-not $lockStream -and [DateTime]::UtcNow -lt $deadline) {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
        $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
}
if (-not $lockStream) { throw 'Timed out waiting for the workspace coordinator lock.' }

function Invoke-WorkspaceGit {
    param([Parameter(Mandatory)][string] $Workspace, [Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Workspace @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed in '$Workspace': $($output -join [Environment]::NewLine)" }
    [pscustomobject]@{ ExitCode=$exitCode; Output=@($output | ForEach-Object { [string]$_ }) }
}

function Get-RepositoryConfig {
    param([string] $RepositoryId)
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $RepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$RepositoryId' was not found." }
    $workspace = [IO.Path]::GetFullPath([string]$repository.localWorkspace)
    if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { throw "Workspace is not a Git repository: $workspace" }
    [pscustomobject]@{ Id=$RepositoryId; Workspace=$workspace }
}

function Read-Session {
    param([string] $SessionTaskId)
    $path = Join-Path $stateRoot "tasks\$SessionTaskId\workspace-session.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject][ordered]@{ taskId=$SessionTaskId; repositories=@(); updatedAtUtc=$null } }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Session {
    param($Session)
    $path = Join-Path $stateRoot "tasks\$([string]$Session.taskId)\workspace-session.json"
    $Session | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-Utf8NoBom -Path $path -Content (($Session | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
    $path
}

try {
    $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) {
        Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        [pscustomobject][ordered]@{ schemaVersion='1.0.0'; activeTaskId=$null; switchedAtUtc=$null }
    }
    $activeTaskId = if ($coordinator.PSObject.Properties['activeTaskId']) { [string]$coordinator.activeTaskId } else { '' }
    if ($activeTaskId -eq $TaskId) {
        $sameTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $sameStage = if ($sameTask.PSObject.Properties['currentStage']) { [string]$sameTask.currentStage } else { '' }
        if ($sameStage -eq 'workspace_restore_conflict') {
            $sameSession = Read-Session -SessionTaskId $TaskId
            $unmerged = [Collections.Generic.List[string]]::new()
            $workingChanges = [Collections.Generic.List[string]]::new()
            foreach ($repositoryId in $targetRepositoryIds) {
                $repository = Get-RepositoryConfig -RepositoryId ([string]$repositoryId)
                foreach ($path in @((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('diff','--name-only','--diff-filter=U')).Output | Where-Object { $_ })) { $unmerged.Add("$($repositoryId):$path") }
                foreach ($entry in @((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('status','--porcelain=v1')).Output | Where-Object { $_ })) { $workingChanges.Add("$($repositoryId):$entry") }
            }
            if ($unmerged.Count -or -not $workingChanges.Count) {
                return [pscustomobject]@{ Status='restore-conflict'; TaskId=$TaskId; PreviousTaskId=$TaskId; CoordinatorPath=$coordinatorPath; UnmergedPaths=@($unmerged); Message='Resolve and stage the restored working-tree changes before resuming. The task-specific stash remains preserved.' }
            }
            foreach ($saved in @($sameSession.repositories)) {
                $stashCommit = if ($saved.PSObject.Properties['stashCommit']) { [string]$saved.stashCommit } else { '' }
                if (-not $stashCommit) { continue }
                $stashList = @((Invoke-WorkspaceGit -Workspace ([string]$saved.workspace) -Arguments @('stash','list','--format=%H %gd')).Output)
                $stashRef = @($stashList | ForEach-Object { if ($_ -match ('^' + [regex]::Escape($stashCommit) + '\s+(stash@\{\d+\})$')) { $Matches[1] } } | Where-Object { $_ }) | Select-Object -First 1
                if ($stashRef) { $null = Invoke-WorkspaceGit -Workspace ([string]$saved.workspace) -Arguments @('stash','drop',[string]$stashRef) }
                $saved.stashCommit = $null
                $saved.stashMessage = $null
                $saved.stashRestored = $true
            }
            $sameSessionPath = Write-Session -Session $sameSession
            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage workspace_restore_resolved -Message 'Manual stash conflict resolution was detected; workspace lease is ready to resume.' -Actor orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
            & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor orchestrator -Type workflow-status -Summary 'Task-specific stash was dropped after verified manual conflict resolution.' -Artifact $sameSessionPath -Evidence @($workingChanges) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        return [pscustomobject]@{ Status='already-active'; TaskId=$TaskId; PreviousTaskId=$TaskId; CoordinatorPath=$coordinatorPath }
    }

    if ($activeTaskId) {
        $activeTaskPath = Join-Path $stateRoot "tasks\$activeTaskId\task.json"
        if (Test-Path -LiteralPath $activeTaskPath -PathType Leaf) {
            $activeTask = Get-Content -LiteralPath $activeTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $activeStage = if ($activeTask.PSObject.Properties['currentStage']) { [string]$activeTask.currentStage } else { '' }
            if ([string]$activeTask.status -eq 'running' -or $activeStage -eq 'workspace_restore_conflict') {
                if ($PrepareOnly) { return [pscustomobject]@{ Status='would-queue'; TaskId=$TaskId; PreviousTaskId=$activeTaskId; CoordinatorPath=$coordinatorPath } }
                & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status queued -Stage workspace_queued -Message "Task queued while '$activeTaskId' owns the workspace lease." -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor orchestrator -Type workflow-status -Summary "Workspace queue: waiting for active task '$activeTaskId'." -Artifact $coordinatorPath -Evidence @($activeTaskPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                return [pscustomobject]@{ Status='queued'; TaskId=$TaskId; PreviousTaskId=$activeTaskId; CoordinatorPath=$coordinatorPath }
            }
        }
    }

    if ($PrepareOnly) {
        return [pscustomobject]@{ Status=if ($activeTaskId) { 'would-switch' } else { 'would-activate' }; TaskId=$TaskId; PreviousTaskId=if ($activeTaskId) { $activeTaskId } else { $null }; CoordinatorPath=$coordinatorPath }
    }

    if ($activeTaskId) {
        $activeSession = Read-Session -SessionTaskId $activeTaskId
        $activeTaskPath = Join-Path $stateRoot "tasks\$activeTaskId\task.json"
        $activeTask = if (Test-Path -LiteralPath $activeTaskPath -PathType Leaf) { Get-Content -LiteralPath $activeTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        $activeRepositoryIds = if ($activeTask -and $activeTask.PSObject.Properties['repositoryIds']) { @($activeTask.repositoryIds) } elseif ($activeTask -and $activeTask.PSObject.Properties['repositoryId'] -and $activeTask.repositoryId) { @([string]$activeTask.repositoryId) } else { @() }
        $savedRepositories = [Collections.Generic.List[object]]::new()
        foreach ($repositoryId in $activeRepositoryIds) {
            $repository = Get-RepositoryConfig -RepositoryId ([string]$repositoryId)
            $branch = ((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('branch','--show-current')).Output -join '').Trim()
            if (-not $branch) { throw "Task '$activeTaskId' workspace '$($repository.Workspace)' is detached; automatic switching is unsafe." }
            $existing = @($activeSession.repositories | Where-Object { [string]$_.repositoryId -eq [string]$repositoryId }) | Select-Object -First 1
            if ($existing -and $existing.PSObject.Properties['stashCommit'] -and -not [string]::IsNullOrWhiteSpace([string]$existing.stashCommit)) { throw "Task '$activeTaskId' already has an unrestored stash for '$repositoryId'." }
            $dirty = @((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('status','--porcelain=v1')).Output)
            $stashCommit = $null
            $stashMessage = $null
            if ($dirty.Count -and [bool]$policy.stashUncommittedChanges) {
                $before = ((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('rev-parse','-q','--verify','refs/stash') -AllowFailure).Output -join '').Trim()
                $stashMessage = "development-agent-ecosystem:${activeTaskId}:${repositoryId}:$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
                $stashArguments = @('stash','push')
                if ([bool]$policy.includeUntracked) { $stashArguments += '--include-untracked' }
                $stashArguments += @('-m',$stashMessage)
                $null = Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments $stashArguments
                $stashCommit = ((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('rev-parse','--verify','refs/stash')).Output -join '').Trim()
                if (-not $stashCommit -or $stashCommit -eq $before) { throw "Git did not create a new stash for task '$activeTaskId' repository '$repositoryId'." }
            }
            $savedRepositories.Add([pscustomobject][ordered]@{ repositoryId=[string]$repositoryId; workspace=$repository.Workspace; branch=$branch; stashCommit=if ($stashCommit) { $stashCommit } else { $null }; stashMessage=if ($stashMessage) { $stashMessage } else { $null }; stashRestored=if ($stashCommit) { $false } else { $true } })
        }
        $activeSession.repositories = @($savedRepositories)
        $activeSessionPath = Write-Session -Session $activeSession
        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $activeTaskId -Actor orchestrator -Type workflow-status -Summary "Workspace suspended for task switch to '$TaskId'; uncommitted changes were preserved in task-specific stashes." -Artifact $activeSessionPath -Evidence @($savedRepositories | Where-Object stashCommit | ForEach-Object { [string]$_.stashCommit }) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }

    $targetSession = Read-Session -SessionTaskId $TaskId
    $targetSaved = [Collections.Generic.List[object]]::new()
    foreach ($repositoryId in $targetRepositoryIds) {
        $repository = Get-RepositoryConfig -RepositoryId ([string]$repositoryId)
        $saved = @($targetSession.repositories | Where-Object { [string]$_.repositoryId -eq [string]$repositoryId }) | Select-Object -First 1
        $currentBranch = ((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('branch','--show-current')).Output -join '').Trim()
        $desiredBranch = if ($saved -and $saved.branch) { [string]$saved.branch } elseif (-not $activeTaskId) { $currentBranch } else { [string]$config.runtime.defaultBaseBranch }
        if (-not $desiredBranch) { throw "No safe branch is known for task '$TaskId' repository '$repositoryId'." }
        if ($currentBranch -ne $desiredBranch) { $null = Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('switch',$desiredBranch) }
        $stashCommit = if ($saved -and $saved.PSObject.Properties['stashCommit']) { [string]$saved.stashCommit } else { '' }
        $stashMessage = if ($saved -and $saved.PSObject.Properties['stashMessage']) { [string]$saved.stashMessage } else { '' }
        if ($stashCommit -and [bool]$policy.restoreStashOnActivation) {
            $apply = Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('stash','apply','--index',$stashCommit) -AllowFailure
            if ($apply.ExitCode -ne 0) {
                $targetSession.repositories = @($targetSaved) + @([pscustomobject][ordered]@{ repositoryId=[string]$repositoryId; workspace=$repository.Workspace; branch=$desiredBranch; stashCommit=$stashCommit; stashMessage=$stashMessage; stashRestored=$false })
                $sessionPath = Write-Session -Session $targetSession
                $coordinator | Add-Member -NotePropertyName activeTaskId -NotePropertyValue $TaskId -Force
                $coordinator | Add-Member -NotePropertyName switchedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                Write-Utf8NoBom -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
                $question = "Git could not restore task '$TaskId' stash $stashCommit in '$($repository.Workspace)' without conflicts. Resolve the working tree manually; the stash was preserved and was not dropped."
                $restoreOptions = @(
                    'Resolve the stash conflicts manually while preserving both task and workspace changes, then resume the task.'
                    'Provide a separate clean workspace or branch where the preserved stash can be restored safely.'
                )
                & (Join-Path $PSScriptRoot 'Open-AgentQuestion.ps1') -TaskId $TaskId -AgentId orchestrator -Question $question -Reason 'Automatic conflict resolution could discard or miscombine user-owned changes, so the ecosystem stops before mutating the conflicted files.' -Options $restoreOptions -RecommendedOption $restoreOptions[0] -RecommendationRationale 'Manual conflict resolution in the recorded workspace keeps the existing branch and preserved stash lineage intact.' -Stage workspace_restore_conflict -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                return [pscustomobject]@{ Status='restore-conflict'; TaskId=$TaskId; PreviousTaskId=if ($activeTaskId) { $activeTaskId } else { $null }; RepositoryId=[string]$repositoryId; StashCommit=$stashCommit; SessionPath=$sessionPath }
            }
            $stashList = @((Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('stash','list','--format=%H %gd')).Output)
            $stashRef = @($stashList | ForEach-Object { if ($_ -match ('^' + [regex]::Escape($stashCommit) + '\s+(stash@\{\d+\})$')) { $Matches[1] } } | Where-Object { $_ }) | Select-Object -First 1
            if ($stashRef) { $null = Invoke-WorkspaceGit -Workspace $repository.Workspace -Arguments @('stash','drop',[string]$stashRef) }
            $stashCommit = ''
            $stashMessage = ''
        }
        $targetSaved.Add([pscustomobject][ordered]@{ repositoryId=[string]$repositoryId; workspace=$repository.Workspace; branch=$desiredBranch; stashCommit=if ($stashCommit) { $stashCommit } else { $null }; stashMessage=if ($stashMessage) { $stashMessage } else { $null }; stashRestored=$true })
    }
    $targetSession.repositories = @($targetSaved)
    $targetSessionPath = Write-Session -Session $targetSession
    $now = [DateTime]::UtcNow.ToString('o')
    $coordinator | Add-Member -NotePropertyName activeTaskId -NotePropertyValue $TaskId -Force
    $coordinator | Add-Member -NotePropertyName switchedAtUtc -NotePropertyValue $now -Force
    Write-Utf8NoBom -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor orchestrator -Type workflow-status -Summary "Workspace lease activated for '$TaskId'; task branches and preserved changes are restored." -Artifact $targetSessionPath -Evidence @($targetSaved | ForEach-Object { "$([string]$_.repositoryId):$([string]$_.branch)" }) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    [pscustomobject]@{ Status='active'; TaskId=$TaskId; PreviousTaskId=if ($activeTaskId) { $activeTaskId } else { $null }; CoordinatorPath=$coordinatorPath; SessionPath=$targetSessionPath; Repositories=@($targetSaved) }
}
finally {
    if ($lockStream) { $lockStream.Dispose() }
}
