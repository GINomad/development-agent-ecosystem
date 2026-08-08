[CmdletBinding()]
param(
    [ValidateSet('manual','automate')][string] $Mode,
    [string] $TaskSelector,
    [string] $TaskId,
    [string] $RepositoryId,
    [string] $Workspace,
    [string] $UserInstruction,
    [switch] $Resume,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not $Mode) { $Mode = [string]$config.operation.mode }

if ($Mode -eq 'manual') {
    if (-not $TaskSelector) { throw 'Manual mode requires -TaskSelector (work item ID, URL, or a precise task description).' }
    if (-not $TaskId) {
        $candidate = ($TaskSelector -replace '^.*?([0-9]+).*$', '$1')
        $TaskId = if ($candidate -match '^[0-9]+$') { "task-$candidate" } else { 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    }
}
else {
    if (-not $TaskId) { $TaskId = 'automate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    if (-not $TaskSelector) { $TaskSelector = 'All enabled task sources assigned to the configured user.' }
}

if ($RepositoryId) {
    $repository = @($config.repositories | Where-Object { $_.id -eq $RepositoryId -and $_.enabled }) | Select-Object -First 1
    if (-not $repository) { throw "Enabled repository '$RepositoryId' was not found." }
}
else {
    $repository = @($config.repositories | Where-Object { $_.enabled }) | Select-Object -First 1
}
if (-not $Workspace -and $repository) { $Workspace = [string]$repository.localWorkspace }
if (-not $Workspace -or -not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "Workspace was not found: $Workspace" }
if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.git'))) { throw "Workspace is not a Git repository: $Workspace" }

$knowledgeImport = & (Join-Path $PSScriptRoot 'Import-InitialKnowledge.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$sync = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome -Install
$task = & (Join-Path $PSScriptRoot 'New-AgentTask.ps1') -TaskId $TaskId -TaskSelector $TaskSelector -Mode $Mode -RepositoryId $RepositoryId -Resume:$Resume -ConfigPath $ConfigPath -CodexHome $CodexHome

$knowledgeAgent = @($config.agents | Where-Object { $_.id -eq 'knowledge_keeper' }) | Select-Object -First 1
$knowledgePrompt = [Collections.Generic.List[string]]::new()
foreach ($pathValue in @($knowledgeAgent.promptPaths)) {
    $path = Resolve-EcosystemPath -Value ([string]$pathValue) -Config $config -CodexHome $CodexHome
    $knowledgePrompt.Add((Get-Content -LiteralPath $path -Raw).Trim())
}
$prompt = @"
You are the primary knowledge keeper for the configured development agent ecosystem.

Task ID: $TaskId
Mode: $Mode
Task selector: $TaskSelector
Task state: $($task.TaskRoot)
Ecosystem root: $(Get-EcosystemRoot)
Target workspace: $([IO.Path]::GetFullPath($Workspace))
Repository config ID: $RepositoryId
Additional user instruction: $UserInstruction

Use the custom agents development_requirements_analyst, development_implementer, development_reviewer, and development_pipeline_monitor according to the configured gates. In automate mode, enumerate assigned tasks but process no more than $($config.operation.automate.maxTasksPerRun) tasks in this run. Do not implement held scope. Do not apply proposed review findings without explicit human decisions. Do not perform external writes without explicit authorization.

$($knowledgePrompt -join ([Environment]::NewLine + [Environment]::NewLine))
"@

$result = [pscustomobject]@{
    Mode = $Mode
    TaskId = $TaskId
    TaskRoot = $task.TaskRoot
    Workspace = [IO.Path]::GetFullPath($Workspace)
    ManagedKnowledgeRoot = $knowledgeImport.ManagedRoot
    AgentFiles = @($sync.AgentFiles)
    Prompt = $prompt
}
if ($PrepareOnly) { return $result }

$arguments = @(
    '-C', [IO.Path]::GetFullPath($Workspace),
    '--add-dir', (Get-EcosystemRoot),
    '-a', [string]$config.runtime.approvalPolicy,
    '-s', 'workspace-write',
    '-c', "agents.max_concurrent_threads_per_session=$([int]$config.runtime.maxConcurrentAgents)",
    $prompt
)
& codex @arguments
if ($LASTEXITCODE -ne 0) { throw "Codex exited with code $LASTEXITCODE." }
