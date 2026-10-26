[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateSet('skill','knowledge','repository-map','artifact','context-pack')][string] $SourceKind,
    [Parameter(Mandatory)][ValidateSet('read','used','full-scan')][string] $AccessMode,
    [Parameter(Mandatory)][string] $SourceId,
    [string] $SourceLocation,
    [string] $SourceRevision,
    [string] $RepositoryId,
    [string] $AttemptId,
    [string] $RunId,
    [string] $LeaseId,
    [string] $Detail,
    [ValidateRange(1, 300)][int] $LockTimeoutSeconds = 30,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
if (-not (Test-Path -LiteralPath $taskRoot -PathType Container)) { throw "Task '$TaskId' was not found." }
& (Join-Path $PSScriptRoot 'Write-KnowledgeAccessMetric.ps1') -TaskRoot $taskRoot -TaskId $TaskId -AttemptId $AttemptId -RunId $RunId -LeaseId $LeaseId -AgentId $AgentId -SourceKind $SourceKind -AccessMode $AccessMode -SourceId $SourceId -SourceLocation $SourceLocation -SourceRevision $SourceRevision -RepositoryId $RepositoryId -EvidenceKind declared -Detail $Detail -LockTimeoutSeconds $LockTimeoutSeconds
