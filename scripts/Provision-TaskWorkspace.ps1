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
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $RepositoryIds.Count) { $RepositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.repositoryId) { @([string]$task.repositoryId) } else { @() } }
if (-not $RepositoryIds.Count) { throw "Task '$TaskId' has no repository workspace." }
function Invoke-TaskWorkspaceGit {
    param([Parameter(Mandatory)][string] $WorkingDirectory, [Parameter(Mandatory)][string[]] $Arguments)
    $savedPreference = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = @(& git -C $WorkingDirectory @Arguments 2>&1); $exitCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed in '$WorkingDirectory': $($output -join [Environment]::NewLine)" }
    return @($output | ForEach-Object { [string]$_ })
}
function ConvertTo-WorkspaceResult {
    param([Parameter(Mandatory)] $Manifest)
    [pscustomobject][ordered]@{ RepositoryId=[string]$Manifest.repositoryId; Path=[string]$Manifest.clonePath; Branch=[string]$Manifest.branch; BaseSha=[string]$Manifest.baseSha; Lifecycle=[string]$Manifest.lifecycle; CanonicalOrigin=[string]$Manifest.canonicalOrigin; RunId=[string]$Manifest.runId; LeaseId=[string]$Manifest.leaseId; ManifestPath=[string]$Manifest.manifestPath }
}
$workspaceRoot = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.workspaceRoot) -Config $config -CodexHome $CodexHome
$results = [Collections.Generic.List[object]]::new()
foreach ($repositoryId in @($RepositoryIds | ForEach-Object { [string]$_ } | Select-Object -Unique)) {
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $repositoryId -and [bool]$_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$repositoryId' was not found." }
    $manifestPath = Join-Path $taskRoot "workspaces\$repositoryId.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.taskId -ne $TaskId -or [string]$manifest.repositoryId -ne $repositoryId) { throw "Workspace manifest identity mismatch: $manifestPath" }
        if (-not (Test-Path -LiteralPath (Join-Path ([string]$manifest.clonePath) '.git'))) { throw "Workspace clone is missing: $($manifest.clonePath)" }
        $ownedByAnotherRun = [string]$manifest.lifecycle -in @('provisioning','active') -and ([string]$manifest.leaseId -ne $LeaseId -or [string]$manifest.runId -ne $RunId)
        if ($ownedByAnotherRun) { throw "Task '$TaskId' already owns a different active workspace run for '$repositoryId'." }
        $manifest | Add-Member -NotePropertyName runId -NotePropertyValue $RunId -Force
        $manifest | Add-Member -NotePropertyName leaseId -NotePropertyValue $LeaseId -Force
        $manifest | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'provisioning' -Force
        $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath -Force
        Write-Utf8NoBomAtomic -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        $results.Add((ConvertTo-WorkspaceResult -Manifest $manifest)); continue
    }
    $branchName = if ($task.PSObject.Properties['branchName']) { [string]$task.branchName } else { '' }
    $layout = Get-TaskWorkspaceLayout -WorkspaceRoot $workspaceRoot -TaskId $TaskId -RepositoryId $repositoryId -RunId $RunId -BranchName $branchName
    $clonePath = [IO.Path]::GetFullPath([string]$layout.ClonePath)
    $workspaceRootPrefix = [IO.Path]::GetFullPath($workspaceRoot).TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $clonePath.StartsWith($workspaceRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to provision a task workspace outside '$workspaceRoot': $clonePath" }
    $branch = [string]$layout.Branch
    $conflicts = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter "$repositoryId.json" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and [string]$_.taskId -ne $TaskId -and [string]$_.branch -eq $branch -and [string]$_.canonicalOrigin -eq [string]$repository.url -and [string]$_.lifecycle -ne 'released' })
    if ($conflicts.Count) { throw "Remote branch '$branch' is already owned by task '$($conflicts[0].taskId)'." }
    if (Test-Path -LiteralPath $clonePath) { throw "Workspace path already exists and is not owned by this task: $clonePath" }
    $cloneCreatedByThisRun = $false
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $clonePath) -Force | Out-Null
        $cloneOutput = @(Invoke-TaskWorkspaceGit -WorkingDirectory (Split-Path -Parent $clonePath) -Arguments @('clone','--origin','origin',([string]$repository.url),$clonePath))
        $cloneCreatedByThisRun = Test-Path -LiteralPath $clonePath
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for repository '$repositoryId': $($cloneOutput -join [Environment]::NewLine)" }
        $canonicalOrigin = (Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('remote','get-url','origin') | Select-Object -First 1).Trim()
        if (-not $canonicalOrigin) { throw "Clone for '$repositoryId' has no origin URL." }
        $baseRef = "origin/$([string]$config.runtime.defaultBaseBranch)"
        $baseSha = (Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('rev-parse',$baseRef) | Select-Object -First 1).Trim()
        Invoke-TaskWorkspaceGit -WorkingDirectory $clonePath -Arguments @('checkout','-b',$branch,$baseSha) | Out-Null
        $manifest = [pscustomobject][ordered]@{ schemaVersion='2.0.0'; taskId=$TaskId; repositoryId=$repositoryId; clonePath=$clonePath; canonicalOrigin=$canonicalOrigin; baseSha=$baseSha; branch=$branch; lifecycle='provisioned'; runId=$RunId; leaseId=$LeaseId; createdAtUtc=[DateTime]::UtcNow.ToString('o'); updatedAtUtc=[DateTime]::UtcNow.ToString('o'); manifestPath=$manifestPath }
        Write-Utf8NoBomAtomic -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
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
