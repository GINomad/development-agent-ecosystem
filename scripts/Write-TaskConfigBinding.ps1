[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $ConfigPath,
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$sourceConfigPath = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $sourceConfigPath -PathType Leaf)) { throw "Task configuration source was not found: $sourceConfigPath" }
$config = Get-EcosystemConfig -ConfigPath $sourceConfigPath -CodexHome $CodexHome
$stateRoot = [IO.Path]::GetFullPath((Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome))
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found under the selected configuration state root." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$repositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds | ForEach-Object { [string]$_ }) } else { @([string]$task.repositoryId) })
if (-not $repositoryIds.Count -or @($repositoryIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw "Task '$TaskId' has no valid repository scope." }
$workspaceRoots = [ordered]@{}
foreach ($repositoryId in $repositoryIds) {
    $repository = @($config.repositories | Where-Object { [string]$_.id -eq $repositoryId -and $_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Task '$TaskId' repository '$repositoryId' is not enabled by the selected configuration." }
    $workspaceRoots[$repositoryId] = [IO.Path]::GetFullPath(([Environment]::ExpandEnvironmentVariables([string]$repository.localWorkspace) -replace '/', [IO.Path]::DirectorySeparatorChar))
}
$binding = [ordered]@{
    schemaVersion = 1
    taskId = $TaskId
    sourceConfigPath = $sourceConfigPath
    sourceConfigSha256 = (Get-EcosystemFileSha256 -Path $sourceConfigPath)
    stateRoot = $stateRoot
    projectId = [string]$task.projectId
    repositoryIds = @($repositoryIds)
    workspaceRoot = [string]$workspaceRoots[$repositoryIds[0]]
    workspaceRoots = $workspaceRoots
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
}
Write-Utf8NoBomAtomic -Path (Join-Path $taskRoot 'task-config-binding.json') -Content (($binding | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
[pscustomobject]$binding
