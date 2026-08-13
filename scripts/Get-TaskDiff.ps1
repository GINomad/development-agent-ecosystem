[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $RepositoryId,
    [string] $FilePath,
    [ValidateSet('reviewed-commit','all-task-changes')][string] $Scope = 'reviewed-commit',
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
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskRepositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) {
    @($task.repositoryIds | ForEach-Object { [string]$_ })
}
elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) {
    @([string]$task.repositoryId)
}
else { @() })
if (-not $taskRepositoryIds.Count) { throw "Task '$TaskId' does not persist a repository scope." }
if ($RepositoryId -and $RepositoryId -notin $taskRepositoryIds) { throw "Repository '$RepositoryId' is not part of task '$TaskId'." }

$reviewedCommit = $null
if ($Scope -eq 'reviewed-commit') {
    $reviewResultPath = Join-Path $taskRoot 'review-result.json'
    if (Test-Path -LiteralPath $reviewResultPath -PathType Leaf) {
        $reviewResult = Get-Content -LiteralPath $reviewResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewedRevision = [string]$reviewResult.reviewedRevision
        if ($reviewedRevision -match '^git:([0-9a-fA-F]{40,64})(?:;|$)') { $reviewedCommit = $Matches[1].ToLowerInvariant() }
    }
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string] $Workspace,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0)
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Workspace @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($exitCode -notin $AllowedExitCodes) {
        $diagnostic = ($output | Select-Object -Last 8) -join [Environment]::NewLine
        throw ("Git command failed with exit code {0} in '{1}': git {2}{3}{4}" -f $exitCode,$Workspace,($Arguments -join ' '),[Environment]::NewLine,$diagnostic)
    }
    return @($output)
}

function Get-RepositoryDiffState {
    param([Parameter(Mandatory)] $Repository)
    $workspace = [IO.Path]::GetFullPath([string]$Repository.localWorkspace)
    if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { throw "Configured workspace is not a Git repository: $workspace" }
    $head = (Invoke-GitText -Workspace $workspace -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()
    $branch = (Invoke-GitText -Workspace $workspace -Arguments @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).Trim()
    $diffTarget = $null
    $revisionSource = 'task-branch'
    if ($Scope -eq 'reviewed-commit') {
        $diffTarget = $head
        $revisionSource = 'current-head'
        if ($reviewedCommit) {
            $verifiedCommitOutput = @(Invoke-GitText -Workspace $workspace -Arguments @('rev-parse','--verify',"$reviewedCommit^{commit}") -AllowedExitCodes @(0,128))
            if ($verifiedCommitOutput.Count) {
                $diffTarget = [string]$verifiedCommitOutput[0]
                $revisionSource = 'review-result'
            }
        }
        $parentOutput = @(Invoke-GitText -Workspace $workspace -Arguments @('rev-parse',"$diffTarget^") -AllowedExitCodes @(0,128))
        if (-not $parentOutput.Count) { throw "Reviewed commit '$diffTarget' has no resolvable first parent." }
        $diffBase = [string]$parentOutput[0]
        $baseRef = "$diffTarget^"
    }
    else {
        $baseBranch = [string]$config.runtime.defaultBaseBranch
        $baseRef = $null
        foreach ($candidate in @("refs/remotes/origin/$baseBranch", "refs/heads/$baseBranch")) {
            $null = Invoke-GitText -Workspace $workspace -Arguments @('show-ref','--verify','--quiet',$candidate) -AllowedExitCodes @(0,1)
            if ($LASTEXITCODE -eq 0) { $baseRef = $candidate; break }
        }
        if (-not $baseRef) { $baseRef = 'HEAD' }
        $mergeBaseOutput = @(Invoke-GitText -Workspace $workspace -Arguments @('merge-base',$baseRef,'HEAD') -AllowedExitCodes @(0,1))
        $diffBase = if ($mergeBaseOutput.Count) { [string]$mergeBaseOutput[0] } else { 'HEAD' }
    }

    $files = [Collections.Generic.List[object]]::new()
    $trackedArguments = @('diff','--name-status','--find-renames',$diffBase)
    if ($diffTarget) { $trackedArguments += $diffTarget }
    $trackedArguments += '--'
    $trackedLines = Invoke-GitText -Workspace $workspace -Arguments $trackedArguments
    foreach ($line in $trackedLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = @($line.Split([char]9))
        if ($parts.Count -lt 2) { continue }
        $status = [string]$parts[0]
        $oldPath = $null
        $path = [string]$parts[$parts.Count - 1]
        if (($status.StartsWith('R') -or $status.StartsWith('C')) -and $parts.Count -ge 3) { $oldPath = [string]$parts[1] }
        $numstatArguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @('diff','--numstat','--find-renames',$diffBase)) { $numstatArguments.Add($argument) }
        if ($diffTarget) { $numstatArguments.Add($diffTarget) }
        $numstatArguments.Add('--')
        if ($oldPath) { $numstatArguments.Add($oldPath) }
        $numstatArguments.Add($path)
        $numstat = Invoke-GitText -Workspace $workspace -Arguments @($numstatArguments)
        $additions = 0
        $deletions = 0
        $binary = $false
        foreach ($statLine in $numstat) {
            $statParts = @($statLine.Split([char]9))
            if ($statParts.Count -lt 3) { continue }
            if ($statParts[0] -eq '-' -or $statParts[1] -eq '-') { $binary = $true; continue }
            $additions += [int]$statParts[0]
            $deletions += [int]$statParts[1]
        }
        $files.Add([pscustomobject][ordered]@{
            path = $path
            oldPath = $oldPath
            status = $status
            additions = $additions
            deletions = $deletions
            binary = $binary
            untracked = $false
        })
    }
    $knownPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $files) { $null = $knownPaths.Add([string]$file.path) }
    foreach ($path in @(if ($Scope -eq 'all-task-changes') { Invoke-GitText -Workspace $workspace -Arguments @('ls-files','--others','--exclude-standard') } else { @() })) {
        if ([string]::IsNullOrWhiteSpace($path) -or $knownPaths.Contains($path)) { continue }
        $files.Add([pscustomobject][ordered]@{
            path = [string]$path
            oldPath = $null
            status = 'A'
            additions = $null
            deletions = 0
            binary = $false
            untracked = $true
        })
    }
    return [pscustomobject][ordered]@{
        id = [string]$Repository.id
        repository = [string]$Repository.repository
        workspace = $workspace
        branch = $branch
        head = $head
        baseRef = $baseRef
        diffBase = $diffBase
        diffTarget = $diffTarget
        scope = $Scope
        revisionSource = $revisionSource
        files = @($files | Sort-Object path)
    }
}

$repositories = [Collections.Generic.List[object]]::new()
foreach ($id in $taskRepositoryIds) {
    if ($RepositoryId -and $id -ne $RepositoryId) { continue }
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $id -and [bool]$_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$id' was not found." }
    $repositories.Add((Get-RepositoryDiffState -Repository $repository))
}

if ([string]::IsNullOrWhiteSpace($FilePath)) {
    return [pscustomobject][ordered]@{
        TaskId = $TaskId
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Scope = $Scope
        Repositories = @($repositories | ForEach-Object {
            [pscustomobject][ordered]@{
                id = $_.id
                repository = $_.repository
                branch = $_.branch
                head = $_.head
                baseRef = $_.baseRef
                diffBase = $_.diffBase
                diffTarget = $_.diffTarget
                scope = $_.scope
                revisionSource = $_.revisionSource
                files = @($_.files)
            }
        })
    }
}

if (-not $RepositoryId) { throw '-RepositoryId is required when requesting one file patch.' }
$repositoryState = @($repositories | Where-Object { [string]$_.id -eq $RepositoryId }) | Select-Object -First 1
if (-not $repositoryState) { throw "Repository '$RepositoryId' was not resolved." }
$file = @($repositoryState.files | Where-Object { [string]$_.path -ceq $FilePath }) | Select-Object -First 1
if (-not $file) { throw "File '$FilePath' is not present in the current task diff." }

$contextLines = [int]$config.ui.diffContextLines
$maximumBytes = [int]$config.ui.diffMaxBytes
if ([bool]$file.untracked) {
    $patchLines = Invoke-GitText -Workspace $repositoryState.workspace -Arguments @('diff','--no-index','--no-ext-diff','--no-color',"--unified=$contextLines",'--','/dev/null',[string]$file.path) -AllowedExitCodes @(0,1,-1)
}
else {
    $patchArguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('diff','--no-ext-diff','--no-color','--find-renames',"--unified=$contextLines",[string]$repositoryState.diffBase)) { $patchArguments.Add($argument) }
    if ($repositoryState.diffTarget) { $patchArguments.Add([string]$repositoryState.diffTarget) }
    $patchArguments.Add('--')
    if ($file.oldPath) { $patchArguments.Add([string]$file.oldPath) }
    $patchArguments.Add([string]$file.path)
    $patchLines = Invoke-GitText -Workspace $repositoryState.workspace -Arguments @($patchArguments)
}
$patch = $patchLines -join [Environment]::NewLine
$encoding = New-Object Text.UTF8Encoding($false, $false)
$patchBytes = $encoding.GetBytes($patch)
$truncated = $patchBytes.Length -gt $maximumBytes
if ($truncated) {
    $patch = $encoding.GetString($patchBytes, 0, $maximumBytes) + [Environment]::NewLine + '[diff truncated at configured byte limit]'
}
[pscustomobject][ordered]@{
    TaskId = $TaskId
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    RepositoryId = $RepositoryId
    Repository = [string]$repositoryState.repository
    Branch = [string]$repositoryState.branch
    Head = [string]$repositoryState.head
    BaseRef = [string]$repositoryState.baseRef
    DiffBase = [string]$repositoryState.diffBase
    DiffTarget = [string]$repositoryState.diffTarget
    Scope = [string]$repositoryState.scope
    RevisionSource = [string]$repositoryState.revisionSource
    File = $file
    Patch = $patch
    Length = $patchBytes.Length
    Truncated = $truncated
}
