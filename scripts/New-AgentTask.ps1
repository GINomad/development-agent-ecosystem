[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $TaskSelector,
    [Parameter(Mandatory)][ValidateSet('manual','automate')][string] $Mode,
    [string] $RepositoryId,
    [switch] $Resume,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if ((Test-Path -LiteralPath $taskPath) -and -not $Resume) {
    throw "Task '$TaskId' already exists. Use -Resume to continue it."
}
New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $taskPath)) {
    $task = [ordered]@{
        taskId = $TaskId
        selector = $TaskSelector
        mode = $Mode
        repositoryId = if ($RepositoryId) { $RepositoryId } else { $null }
        status = 'created'
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        currentStage = 'not-started'
        lastMessage = 'Task created. Workflow has not started yet.'
        agentStatuses = [ordered]@{
            knowledge_keeper = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            requirements_analyst = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            developer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            reviewer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            pipeline_monitor = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            health_check = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
        }
    }
    Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'user' -Type 'task-created' -Summary "Task selected in $Mode mode: $TaskSelector" -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
[pscustomobject]@{ TaskId = $TaskId; TaskRoot = $taskRoot; TaskPath = $taskPath; Resumed = [bool]$Resume }
