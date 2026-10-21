[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Config,
    [Parameter(Mandatory)][string] $AgentId,
    [string[]] $RepositoryIds = @(),
    [switch] $AllProjects,
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Resolve-EcosystemPath -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') }
if ($AgentId -notin @('requirements_analyst','developer','reviewer','review_verifier','knowledge_keeper')) { return }
foreach ($project in @($Config.projects)) {
    if (-not [bool]$project.enabled) { continue }
    if (-not $AllProjects -and -not @($project.repositoryIds | Where-Object { [string]$_ -in $RepositoryIds }).Count) { continue }
    $domainRoot = Resolve-EcosystemPath -Value ([string]$project.domainKnowledgeRoot) -Config $Config -CodexHome $CodexHome
    $skillRoot = Join-Path $domainRoot 'skills'
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) { continue }
    if ((Get-Item -LiteralPath $skillRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Project skill root must not be a reparse point.' }
    foreach ($directory in @(Get-ChildItem -LiteralPath $skillRoot -Directory | Sort-Object Name)) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Project skill directory must not be a reparse point.' }
        $path = Join-Path $directory.FullName 'SKILL.md'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Project skill file must not be a reparse point.' }
            $path
        }
    }
}
