[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $HostConfigPath,
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function Get-TaskScope {
    param([Parameter(Mandatory)]$Task)
    $repositoryIds = @(if ($Task.PSObject.Properties['repositoryIds']) { @($Task.repositoryIds | ForEach-Object { [string]$_ }) } else { @([string]$Task.repositoryId) })
    if (-not $repositoryIds.Count -or @($repositoryIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw "Task '$TaskId' has no valid repository scope." }
    [pscustomobject]@{ ProjectId=[string]$Task.projectId; RepositoryIds=@($repositoryIds) }
}
function Assert-ConfigMatchesTask {
    param([Parameter(Mandatory)]$CandidateConfig, [Parameter(Mandatory)]$TaskScope)
    $project = @($CandidateConfig.projects | Where-Object { [string]$_.id -eq $TaskScope.ProjectId -and $_.enabled }) | Select-Object -First 1
    if (-not $project) { throw "Task '$TaskId' project '$($TaskScope.ProjectId)' is not enabled by the selected configuration." }
    $projectRepositoryIds = @($project.repositoryIds | ForEach-Object { [string]$_ })
    $foreignRepositoryIds = @($TaskScope.RepositoryIds | Where-Object { $_ -notin $projectRepositoryIds })
    if ($foreignRepositoryIds.Count) { throw "Task '$TaskId' repositories do not belong to project '$($TaskScope.ProjectId)': $($foreignRepositoryIds -join ', ')." }
    foreach ($repositoryId in $TaskScope.RepositoryIds) {
        if (-not @($CandidateConfig.repositories | Where-Object { [string]$_.id -eq $repositoryId -and $_.enabled }).Count) { throw "Task '$TaskId' repository '$repositoryId' is not enabled by the selected configuration." }
    }
}

$hostPath = [IO.Path]::GetFullPath($HostConfigPath)
$hostConfig = Get-EcosystemConfig -ConfigPath $hostPath -CodexHome $CodexHome
$hostStateRoot = [IO.Path]::GetFullPath((Get-EcosystemStateRoot -Config $hostConfig -CodexHome $CodexHome))
$taskRoot = Join-Path $hostStateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found under the dashboard configuration state root." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bindingPath = Join-Path $taskRoot 'task-config-binding.json'
if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) {
    [pscustomobject]@{ ConfigPath=$hostPath; Config=$hostConfig; Binding=$null; IsLegacy=$true }
    return
}
$scope = Get-TaskScope -Task $task
$binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$binding.schemaVersion -ne 1 -or [string]$binding.taskId -ne $TaskId) { throw "Task '$TaskId' has an invalid configuration binding." }
$sourcePath = [IO.Path]::GetFullPath([string]$binding.sourceConfigPath)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Task '$TaskId' configuration binding source does not exist." }
$taskPrefix = $taskRoot.TrimEnd('\') + '\'
if ($sourcePath.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Task '$TaskId' configuration binding may not reference an execution snapshot." }
$isHostConfigBinding = $sourcePath.Equals($hostPath, [StringComparison]::OrdinalIgnoreCase)
if (-not $isHostConfigBinding -and (Get-EcosystemFileSha256 -Path $sourcePath) -ne [string]$binding.sourceConfigSha256) { throw "Task '$TaskId' configuration binding hash does not match its source." }
$sourceConfig = if ($isHostConfigBinding) { $hostConfig } else { Get-EcosystemConfig -ConfigPath $sourcePath -CodexHome $CodexHome }
$sourceStateRoot = [IO.Path]::GetFullPath((Get-EcosystemStateRoot -Config $sourceConfig -CodexHome $CodexHome))
if ($sourceStateRoot -ne $hostStateRoot -or $sourceStateRoot -ne [IO.Path]::GetFullPath([string]$binding.stateRoot)) { throw "Task '$TaskId' configuration binding state root does not match the dashboard state root." }
if ([string]$binding.projectId -ne $scope.ProjectId -or ((@($binding.repositoryIds | ForEach-Object { [string]$_ }) -join '|') -ne (@($scope.RepositoryIds) -join '|'))) { throw "Task '$TaskId' configuration binding scope does not match task metadata." }
Assert-ConfigMatchesTask -CandidateConfig $sourceConfig -TaskScope $scope
foreach ($repositoryId in $scope.RepositoryIds) {
    $repository = @($sourceConfig.repositories | Where-Object { [string]$_.id -eq $repositoryId }) | Select-Object -First 1
    $actualRoot = [IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables([string]$repository.localWorkspace) -replace '/', [IO.Path]::DirectorySeparatorChar))
    if ($actualRoot -ne [IO.Path]::GetFullPath([string]$binding.workspaceRoots.$repositoryId)) { throw "Task '$TaskId' configuration binding workspace root changed for repository '$repositoryId'." }
}
[pscustomobject]@{ ConfigPath=$sourcePath; Config=$sourceConfig; Binding=$binding; IsLegacy=$false; HostConfigRefreshed=$isHostConfigBinding }
