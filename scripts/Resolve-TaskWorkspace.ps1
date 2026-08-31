[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $RepositoryId,
    [switch] $AllowReleased,
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
$manifestDirectory = Join-Path $taskRoot 'workspaces'
$manifestPaths = @(if ($RepositoryId) { Join-Path $manifestDirectory "$RepositoryId.json" } else { Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object FullName })
if (-not $manifestPaths.Count) { throw "Task '$TaskId' has no provisioned workspace manifest." }
$results = [Collections.Generic.List[object]]::new()
foreach ($manifestPath in $manifestPaths) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Workspace manifest was not found: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.taskId -ne $TaskId) { throw "Workspace manifest does not belong to task '$TaskId': $manifestPath" }
    if ($RepositoryId -and [string]$manifest.repositoryId -ne $RepositoryId) { throw "Workspace manifest repository mismatch: $manifestPath" }
    if (-not $AllowReleased -and [string]$manifest.lifecycle -eq 'released') { throw "Workspace for task '$TaskId' repository '$($manifest.repositoryId)' is released." }
    $clonePath = [IO.Path]::GetFullPath([string]$manifest.clonePath)
    if (-not (Test-Path -LiteralPath (Join-Path $clonePath '.git'))) { throw "Workspace clone is missing: $clonePath" }
    $results.Add([pscustomobject][ordered]@{ RepositoryId=[string]$manifest.repositoryId; Path=$clonePath; Branch=[string]$manifest.branch; BaseSha=[string]$manifest.baseSha; Lifecycle=[string]$manifest.lifecycle; CanonicalOrigin=[string]$manifest.canonicalOrigin; RunId=[string]$manifest.runId; LeaseId=[string]$manifest.leaseId; ManifestPath=[string]$manifestPath })
}
if ($RepositoryId) { return $results[0] }
return @($results)
