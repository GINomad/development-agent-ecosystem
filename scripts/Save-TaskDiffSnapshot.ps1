[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
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
$snapshotRoot = Join-Path $taskRoot 'diff-snapshots'
$snapshotPath = Join-Path $snapshotRoot 'dashboard-diff.json'
$commitRoot = Join-Path $snapshotRoot 'reviewed-commits'

function Invoke-SnapshotGitText {
    param([Parameter(Mandatory)][string] $Workspace, [Parameter(Mandatory)][string[]] $Arguments)
    $prior = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $output = @(& git -C $Workspace @Arguments 2>&1 | ForEach-Object { [string]$_ }); $exitCode = [int]$LASTEXITCODE }
    finally { $ErrorActionPreference = $prior }
    if ($exitCode -ne 0) { throw "Git preservation command failed: git $($Arguments -join ' ')" }
    return $output
}

$repositories = [Collections.Generic.List[object]]::new()
foreach ($scope in @('reviewed-commit','all-task-changes')) {
    $index = & (Join-Path $PSScriptRoot 'Get-TaskDiff.ps1') -TaskId $TaskId -Scope $scope -ConfigPath $ConfigPath -CodexHome $CodexHome
    foreach ($repository in @($index.Repositories)) {
        $entry = @($repositories | Where-Object { [string]$_.id -eq [string]$repository.id }) | Select-Object -First 1
        if (-not $entry) {
            $entry = [pscustomobject][ordered]@{ id=[string]$repository.id; repository=[string]$repository.repository; branch=[string]$repository.branch; head=[string]$repository.head; scopes=[ordered]@{} }
            $repositories.Add($entry)
        }
        $patches = [Collections.Generic.List[object]]::new()
        foreach ($file in @($repository.files)) {
            $patch = & (Join-Path $PSScriptRoot 'Get-TaskDiff.ps1') -TaskId $TaskId -RepositoryId ([string]$repository.id) -FilePath ([string]$file.path) -Scope $scope -ConfigPath $ConfigPath -CodexHome $CodexHome
            $patches.Add([pscustomobject][ordered]@{ path=[string]$file.path; file=$patch.File; patch=[string]$patch.Patch; length=[int]$patch.Length; truncated=[bool]$patch.Truncated })
        }
        $scopeEntry = [pscustomobject][ordered]@{ baseRef=[string]$repository.baseRef; diffBase=[string]$repository.diffBase; diffTarget=[string]$repository.diffTarget; revisionSource=[string]$repository.revisionSource; files=@($repository.files); patches=@($patches) }
        $entry.scopes[$scope] = $scopeEntry
        if ($scope -eq 'reviewed-commit' -and -not [string]::IsNullOrWhiteSpace([string]$repository.diffTarget)) {
            $workspace = & (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -RepositoryId ([string]$repository.id) -AllowReleased -ConfigPath $ConfigPath -CodexHome $CodexHome
            $repositoryCommitRoot = Join-Path $commitRoot ([string]$repository.id)
            New-Item -ItemType Directory -Path $repositoryCommitRoot -Force | Out-Null
            $commitPath = Join-Path $repositoryCommitRoot ("$([string]$repository.diffTarget).patch")
            if (-not (Test-Path -LiteralPath $commitPath -PathType Leaf)) {
                $text = (Invoke-SnapshotGitText -Workspace ([string]$workspace.Path) -Arguments @('format-patch','--stdout','--full-index','--binary',"$([string]$repository.diffTarget)^..$([string]$repository.diffTarget)")) -join [Environment]::NewLine
                if ([string]::IsNullOrWhiteSpace($text)) { throw "Reviewed commit patch is empty: $($repository.diffTarget)" }
                Write-Utf8NoBomAtomic -Path $commitPath -Content ($text + [Environment]::NewLine)
            }
            $scopeEntry | Add-Member -NotePropertyName commitPatchRelativePath -NotePropertyValue ("diff-snapshots/reviewed-commits/$([string]$repository.id)/$([string]$repository.diffTarget).patch")
            $scopeEntry | Add-Member -NotePropertyName commitPatchSha256 -NotePropertyValue (Get-EcosystemFileSha256 -Path $commitPath)
        }
    }
}
New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
$snapshot = [pscustomobject][ordered]@{ schemaVersion='1.0.0'; taskId=$TaskId; capturedAtUtc=[DateTime]::UtcNow.ToString('o'); repositories=@($repositories) }
Write-Utf8NoBomAtomic -Path $snapshotPath -Content (($snapshot | ConvertTo-Json -Depth 32) + [Environment]::NewLine)
[pscustomobject][ordered]@{ TaskId=$TaskId; SnapshotPath=$snapshotPath; RepositoryCount=$repositories.Count; CapturedAtUtc=$snapshot.capturedAtUtc }
