[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string[]] $RepositoryIds = @(),
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $LeaseId,
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
$manifestLockPath = Join-Path $taskRoot 'workspace-manifests.lock'
$provisioningLockPath = Join-Path $taskRoot 'workspace-provisioning.lock'
$lockMetricsPath = Join-Path $stateRoot 'health\lock-metrics.jsonl'
$lockCorrelationId = "$TaskId/$RunId/$LeaseId"
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $RepositoryIds.Count) { $RepositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.repositoryId) { @([string]$task.repositoryId) } else { @() } }
if (-not $RepositoryIds.Count) { throw "Task '$TaskId' has no repository workspace." }
$taskRepositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique) } elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) { @([string]$task.repositoryId) } else { @() })
$requestedRepositoryIds = @($RepositoryIds | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
if (-not $taskRepositoryIds.Count -or ($taskRepositoryIds -join '|') -ne ($requestedRepositoryIds -join '|')) { throw "Workspace provisioning for task '$TaskId' must use exactly its persisted repository scope: $($taskRepositoryIds -join ', ')." }
$RepositoryIds = $taskRepositoryIds
function Assert-TaskWorkspaceGitRoot {
    param([Parameter(Mandatory)][string] $WorkingDirectory)
    $expectedRoot = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd([char[]]@('\','/'))
    if (-not (Test-Path -LiteralPath (Join-Path $expectedRoot '.git'))) { throw "Workspace has no own Git metadata: $expectedRoot" }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $topLevel = @(& git -C $expectedRoot rev-parse --show-toplevel 2>&1)
        $probeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($probeExit -ne 0 -or $topLevel.Count -ne 1 -or
        -not [IO.Path]::GetFullPath([string]$topLevel[0]).TrimEnd([char[]]@('\','/')).Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Workspace Git root does not match the requested directory; refusing parent-repository fallback: $expectedRoot"
    }
}
function Invoke-TaskWorkspaceGit {
    param([Parameter(Mandatory)][string] $WorkingDirectory, [Parameter(Mandatory)][string[]] $Arguments)
    # Clone intentionally runs in a destination parent; all other operations
    # must resolve to the exact owned checkout, not an enclosing repository.
    if ($Arguments[0] -ne 'clone') { Assert-TaskWorkspaceGitRoot -WorkingDirectory $WorkingDirectory }
    $savedPreference = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = @(& git -C $WorkingDirectory @Arguments 2>&1); $exitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed in '$WorkingDirectory': $($output -join [Environment]::NewLine)" }
    return @($output | ForEach-Object { [string]$_ })
}
function Test-TaskWorkspaceGitRef {
    param([Parameter(Mandatory)][string] $WorkingDirectory, [Parameter(Mandatory)][string] $Reference)
    Assert-TaskWorkspaceGitRoot -WorkingDirectory $WorkingDirectory
    $savedPreference = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $null = @(& git -C $WorkingDirectory show-ref --verify --quiet $Reference 2>&1); $exitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -notin @(0,1)) { throw "git show-ref --verify --quiet $Reference failed in '$WorkingDirectory'." }
    return $exitCode -eq 0
}
function Test-EquivalentGitRemoteUrl {
    param([Parameter(Mandatory)][string] $Left, [Parameter(Mandatory)][string] $Right)
    try {
        $leftUri = [Uri]$Left
        $rightUri = [Uri]$Right
        if ($leftUri.IsAbsoluteUri -and $rightUri.IsAbsoluteUri) {
            return $leftUri.Scheme.Equals($rightUri.Scheme, [StringComparison]::OrdinalIgnoreCase) -and
                $leftUri.Host.Equals($rightUri.Host, [StringComparison]::OrdinalIgnoreCase) -and
                $leftUri.Port -eq $rightUri.Port -and
                ($leftUri.AbsolutePath.TrimEnd('/')).Equals($rightUri.AbsolutePath.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)
        }
    }
    catch { }
    return $Left.TrimEnd('/').Equals($Right.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)
}
function ConvertTo-WorkspaceResult {
    param([Parameter(Mandatory)] $Manifest)
    [pscustomobject][ordered]@{ RepositoryId=[string]$Manifest.repositoryId; Path=[string]$Manifest.clonePath; Branch=[string]$Manifest.branch; BaseSha=[string]$Manifest.baseSha; Lifecycle=[string]$Manifest.lifecycle; CanonicalOrigin=[string]$Manifest.canonicalOrigin; RunId=[string]$Manifest.runId; LeaseId=[string]$Manifest.leaseId; ManifestPath=[string]$Manifest.manifestPath }
}
function Write-WorkspaceManifestLocked {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Manifest)
    Invoke-EcosystemFileLock -LockPath $manifestLockPath -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -MetricsPath $lockMetricsPath -CorrelationId $lockCorrelationId -Action {
        # Manifest -> coordinator is the only commit lock order.  The global
        # lock covers no Git work and no task-state lock acquisition.
        $ownsLease = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -MetricsPath $lockMetricsPath -CorrelationId $lockCorrelationId -Action {
            if (-not (Test-Path -LiteralPath $coordinatorPath -PathType Leaf)) { return $false }
            $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId -and [string]$_.runId -eq $RunId -and [string]$_.leaseId -eq $LeaseId }).Count -ne 1) { return $false }
            Write-Utf8NoBomAtomic -Path $Path -Content (($Manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
            return $true
        }
        if (-not $ownsLease) { throw "Workspace provisioning authority was released or replaced for task '$TaskId' run '$RunId'." }
    } | Out-Null
}

# Serialize same-task provisioning, including clone cleanup.  This lock is never
# held by coordinator admission, so different tasks remain independent.
$provisioningLock = $null
$provisioningDeadline = [DateTime]::UtcNow.AddSeconds([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds)
do {
    try { $provisioningLock = [IO.File]::Open($provisioningLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { if ([DateTime]::UtcNow -ge $provisioningDeadline) { throw "Timed out acquiring workspace provisioning lock for task '$TaskId'." }; Start-Sleep -Milliseconds 50 }
} while ($null -eq $provisioningLock)
try {
    $workspaceRoot = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.workspaceRoot) -Config $config -CodexHome $CodexHome
    $results = [Collections.Generic.List[object]]::new()
    $preservedBrokenClonePath = $null
    foreach ($repositoryId in @($RepositoryIds | ForEach-Object { [string]$_ } | Select-Object -Unique)) {
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $repositoryId -and [bool]$_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$repositoryId' was not found." }
    $manifestPath = Join-Path $taskRoot "workspaces\$repositoryId.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.taskId -ne $TaskId -or [string]$manifest.repositoryId -ne $repositoryId) { throw "Workspace manifest identity mismatch: $manifestPath" }
        $cloneExists = Test-Path -LiteralPath (Join-Path ([string]$manifest.clonePath) '.git') -PathType Container
        # Preserve a non-Git released directory as evidence; provision a new run-specific clone instead of deleting it.
        $recoverableWorkspaceNeedsProvisioning = [string]$manifest.lifecycle -in @('cleaned','released') -and -not $cloneExists
        if ($recoverableWorkspaceNeedsProvisioning -and [string]$manifest.lifecycle -eq 'released') { $preservedBrokenClonePath = [string]$manifest.clonePath }
        if (-not $recoverableWorkspaceNeedsProvisioning) {
            if (-not $cloneExists) { throw "Workspace clone is missing: $($manifest.clonePath)" }
            Assert-TaskWorkspaceGitRoot -WorkingDirectory ([string]$manifest.clonePath)
            $ownedByAnotherRun = [string]$manifest.lifecycle -in @('provisioning','active') -and ([string]$manifest.leaseId -ne $LeaseId -or [string]$manifest.runId -ne $RunId)
            if ($ownedByAnotherRun) { throw "Task '$TaskId' already owns a different active workspace run for '$repositoryId'." }
            $manifest | Add-Member -NotePropertyName runId -NotePropertyValue $RunId -Force
            $manifest | Add-Member -NotePropertyName leaseId -NotePropertyValue $LeaseId -Force
            $manifest | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'provisioning' -Force
            $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath -Force
            Write-WorkspaceManifestLocked -Path $manifestPath -Manifest $manifest
            $results.Add((ConvertTo-WorkspaceResult -Manifest $manifest)); continue
        }
    }
    $branchName = if ($task.PSObject.Properties['branchName']) { [string]$task.branchName } else { '' }
    $layout = Get-TaskWorkspaceLayout -WorkspaceRoot $workspaceRoot -TaskId $TaskId -RepositoryId $repositoryId -RunId $RunId -BranchName $branchName
    $clonePath = [IO.Path]::GetFullPath([string]$layout.ClonePath)
    if ($preservedBrokenClonePath) { $clonePath = [IO.Path]::GetFullPath("$clonePath-recovery-$RunId") }
    $workspaceRootPrefix = [IO.Path]::GetFullPath($workspaceRoot).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $clonePath.StartsWith($workspaceRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to provision a task workspace outside '$workspaceRoot': $clonePath" }
    $branch = [string]$layout.Branch
    $conflicts = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter "$repositoryId.json" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and [string]$_.taskId -ne $TaskId -and [string]$_.branch -eq $branch -and [string]$_.canonicalOrigin -eq [string]$repository.url -and [string]$_.lifecycle -notin @('released','cleaned') })
    if ($conflicts.Count) { throw "Remote branch '$branch' is already owned by task '$($conflicts[0].taskId)'." }
    if (Test-Path -LiteralPath $clonePath) { throw "Workspace path already exists and is not owned by this task: $clonePath" }
    $cloneCreatedByThisRun = $false
    try {
        $baseBranch = if ($repository.PSObject.Properties['baseBranch'] -and -not [string]::IsNullOrWhiteSpace([string]$repository.baseBranch)) { [string]$repository.baseBranch } else { [string]$config.runtime.defaultBaseBranch }
        $cloneSource = if ($repository.PSObject.Properties['workspaceCloneSource'] -and -not [string]::IsNullOrWhiteSpace([string]$repository.workspaceCloneSource)) { [IO.Path]::GetFullPath([string]$repository.workspaceCloneSource) } else { $null }
        $baseSha = $null
        if ($cloneSource) {
            if (-not (Test-Path -LiteralPath (Join-Path $cloneSource '.git') -PathType Container)) { throw "Repository '$repositoryId' workspaceCloneSource is not a Git checkout: $cloneSource" }
            $sourceOrigin = (Invoke-TaskWorkspaceGit -WorkingDirectory $cloneSource -Arguments @('remote','get-url','origin') | Select-Object -First 1).Trim()
            if (-not $sourceOrigin -or -not (Test-EquivalentGitRemoteUrl -Left $sourceOrigin -Right ([string]$repository.url))) { throw "Repository '$repositoryId' workspaceCloneSource origin does not match its configured repository URL." }
            $sourceBaseRef = $null
            foreach ($candidate in @("refs/remotes/origin/$baseBranch", "refs/heads/$baseBranch")) {
                if (Test-TaskWorkspaceGitRef -WorkingDirectory $cloneSource -Reference $candidate) { $sourceBaseRef = $candidate; break }
            }
            if (-not $sourceBaseRef) { throw "Repository '$repositoryId' workspaceCloneSource is missing base branch '$baseBranch'." }
            $baseSha = (Invoke-TaskWorkspaceGit -WorkingDirectory $cloneSource -Arguments @('rev-parse',$sourceBaseRef) | Select-Object -First 1).Trim()
        }
        $cloneArguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @('clone','--origin','origin')) { $cloneArguments.Add($argument) }
        if ($cloneSource) {
            $cloneArguments.Add('--no-hardlinks')
            $cloneArguments.Add($cloneSource)
        }
        else {
            $cloneArguments.Add([string]$repository.url)
        }
        $cloneArguments.Add($clonePath)
        New-Item -ItemType Directory -Path (Split-Path -Parent $clonePath) -Force | Out-Null
        $cloneOutput = @(Invoke-TaskWorkspaceGit -WorkingDirectory (Split-Path -Parent $clonePath) -Arguments ([string[]]$cloneArguments.ToArray()))
        $cloneCreatedByThisRun = Test-Path -LiteralPath $clonePath
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for repository '$repositoryId': $($cloneOutput -join [Environment]::NewLine)" }
        if ($cloneSource) { Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('remote','set-url','origin',([string]$repository.url)) | Out-Null }
        if ($preservedBrokenClonePath) { Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('fetch','origin',"refs/heads/${branch}:refs/remotes/origin/${branch}") | Out-Null }
        $canonicalOrigin = (Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('remote','get-url','origin') | Select-Object -First 1).Trim()
        if (-not $canonicalOrigin -or -not (Test-EquivalentGitRemoteUrl -Left $canonicalOrigin -Right ([string]$repository.url))) { throw "Clone for '$repositoryId' does not retain the configured origin URL." }
        if ($cloneSource) {
            Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('cat-file','-e',"$baseSha^{commit}") | Out-Null
        }
        else {
            $baseRef = "origin/$baseBranch"
            $baseSha = (Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('rev-parse',$baseRef) | Select-Object -First 1).Trim()
        }
        $checkoutStart = $baseSha
        if ($preservedBrokenClonePath -and (Test-TaskWorkspaceGitRef -WorkingDirectory $clonePath -Reference "refs/remotes/origin/$branch")) { $checkoutStart = "origin/$branch" }
        Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('checkout','-B',$branch,$checkoutStart) | Out-Null
        $manifest = [pscustomobject][ordered]@{ schemaVersion='2.0.0'; taskId=$TaskId; repositoryId=$repositoryId; clonePath=$clonePath; canonicalOrigin=$canonicalOrigin; cloneSource=$cloneSource; baseBranch=$baseBranch; baseSha=$baseSha; branch=$branch; lifecycle='provisioned'; runId=$RunId; leaseId=$LeaseId; createdAtUtc=[DateTime]::UtcNow.ToString('o'); updatedAtUtc=[DateTime]::UtcNow.ToString('o'); recoveredFromPath=if ($preservedBrokenClonePath) { $preservedBrokenClonePath } else { $null }; manifestPath=$manifestPath }
        Write-WorkspaceManifestLocked -Path $manifestPath -Manifest $manifest
        $results.Add((ConvertTo-WorkspaceResult -Manifest $manifest))
    }
    catch {
        $provisioningFailure = $_.Exception.Message
        if ($cloneCreatedByThisRun -and (Test-Path -LiteralPath $clonePath)) {
            try { Remove-Item -LiteralPath $clonePath -Recurse -Force -ErrorAction Stop }
            catch { throw "Workspace provisioning failed for '$repositoryId': $provisioningFailure Automatic cleanup of '$clonePath' also failed: $($_.Exception.Message)" }
        }
        throw $provisioningFailure
    }
    }
    return @($results)
}
finally {
    if ($provisioningLock) { $provisioningLock.Dispose() }
}
