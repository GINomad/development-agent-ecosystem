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
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedBranch = if ($task.PSObject.Properties['branchName']) { [string]$task.branchName } else { '' }
if ([string]::IsNullOrWhiteSpace($expectedBranch)) { return @() }
if (-not (Test-TaskBranchName -BranchName $expectedBranch)) { throw "Task '$TaskId' has invalid branch metadata '$expectedBranch'." }

function Invoke-WorkspaceGit {
    param(
        [Parameter(Mandatory)][string] $Workspace,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0)
    )
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Workspace @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -notin $AllowedExitCodes) { throw "git $($Arguments -join ' ') failed with exit code $exitCode in '$Workspace': $(@($output | Select-Object -Last 8) -join ' ')" }
    return [pscustomobject]@{ ExitCode=$exitCode; Output=@($output) }
}

$workspaceRoot = [IO.Path]::GetFullPath((Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.workspaceRoot) -Config $config -CodexHome $CodexHome))
$workspaceRootPrefix = $workspaceRoot.TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar
$results = [Collections.Generic.List[object]]::new()
foreach ($repositoryId in @(if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.repositoryId) { @([string]$task.repositoryId) } else { @() })) {
    $manifestPath = Join-Path $taskRoot "workspaces\$repositoryId.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.taskId -ne $TaskId -or [string]$manifest.repositoryId -ne [string]$repositoryId) { throw "Workspace manifest identity mismatch: $manifestPath" }
    $workspace = [IO.Path]::GetFullPath([string]$manifest.clonePath)
    if (-not $workspace.StartsWith($workspaceRootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Workspace manifest escapes the configured workspace root: $workspace" }
    if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { continue }
    $manifestBranch = [string]$manifest.branch
    $currentBranch = [string]((Invoke-WorkspaceGit -Workspace $workspace -Arguments @('branch','--show-current')).Output | Select-Object -First 1)
    if ($manifestBranch -ne $expectedBranch -and (Test-TaskBranchName -BranchName $manifestBranch)) { throw "Workspace manifest branch '$manifestBranch' does not match task branch '$expectedBranch' and is not a legacy branch." }
    if ($manifestBranch -eq $expectedBranch -and $currentBranch -eq $expectedBranch) { continue }
    $head = [string]((Invoke-WorkspaceGit -Workspace $workspace -Arguments @('rev-parse','HEAD')).Output | Select-Object -First 1)
    if ($head -notmatch '^[0-9a-fA-F]{40}$') { throw "Could not resolve HEAD for task workspace '$workspace'." }
    $conflict = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'tasks') -Filter "$repositoryId.json" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and [string]$_.taskId -ne $TaskId -and [string]$_.branch -eq $expectedBranch -and [string]$_.canonicalOrigin -eq [string]$manifest.canonicalOrigin -and [string]$_.lifecycle -notin @('released','cleaned') } | Select-Object -First 1)
    if ($conflict.Count) { throw "Task branch '$expectedBranch' is already owned by task '$([string]$conflict[0].taskId)'." }
    $result = [ordered]@{ taskId=$TaskId; repositoryId=[string]$repositoryId; workspace=$workspace; previousManifestBranch=$manifestBranch; previousCurrentBranch=$currentBranch; branch=$expectedBranch; commit=$head.ToLowerInvariant(); status=if ($PrepareOnly) { 'would-migrate' } else { 'migrated' } }
    if ($PrepareOnly) {
        $results.Add([pscustomobject]$result)
        continue
    }
    $branchLookup = Invoke-WorkspaceGit -Workspace $workspace -Arguments @('rev-parse','--verify','--quiet',"refs/heads/$expectedBranch") -AllowedExitCodes @(0,1)
    if ($branchLookup.ExitCode -eq 0) {
        $existingCommit = [string]($branchLookup.Output | Select-Object -First 1)
        if ($existingCommit -ne $head) { throw "Existing local branch '$expectedBranch' points to '$existingCommit' instead of task HEAD '$head'." }
    }
    else {
        Invoke-WorkspaceGit -Workspace $workspace -Arguments @('branch',$expectedBranch,$head) | Out-Null
    }
    if ($currentBranch -ne $expectedBranch) { Invoke-WorkspaceGit -Workspace $workspace -Arguments @('checkout',$expectedBranch) | Out-Null }
    $verifiedBranch = [string]((Invoke-WorkspaceGit -Workspace $workspace -Arguments @('branch','--show-current')).Output | Select-Object -First 1)
    $verifiedHead = [string]((Invoke-WorkspaceGit -Workspace $workspace -Arguments @('rev-parse','HEAD')).Output | Select-Object -First 1)
    if ($verifiedBranch -ne $expectedBranch -or $verifiedHead -ne $head) { throw "Legacy branch migration did not preserve task HEAD '$head' on '$expectedBranch'." }
    $manifest | Add-Member -NotePropertyName branch -NotePropertyValue $expectedBranch -Force
    $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-Utf8NoBomAtomic -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
    $results.Add([pscustomobject]$result)
}
return @($results)
