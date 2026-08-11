[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $TaskSelector,
    [Parameter(Mandatory)][ValidateSet('manual','automate')][string] $Mode,
    [string] $RepositoryId,
    [string[]] $RepositoryIds = @(),
    [switch] $Resume,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$selectedRepositoryIds = [Collections.Generic.List[string]]::new()
foreach ($id in @($RepositoryIds) + @($RepositoryId)) {
    $value = [string]$id
    if ([string]::IsNullOrWhiteSpace($value) -or $selectedRepositoryIds.Contains($value)) { continue }
    if (-not @($config.repositories | Where-Object { $_.id -eq $value -and $_.enabled }).Count) { throw "Enabled repository '$value' was not found." }
    $selectedRepositoryIds.Add($value)
}
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
        repositoryId = if ($selectedRepositoryIds.Count) { $selectedRepositoryIds[0] } else { $null }
        repositoryIds = @($selectedRepositoryIds)
        status = 'created'
        createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        currentStage = 'not-started'
        lastMessage = 'Task created. Workflow has not started yet.'
        agentStatuses = [ordered]@{
            orchestrator = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            knowledge_keeper = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            requirements_analyst = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            developer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            reviewer = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            pipeline_monitor = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
            health_check = [ordered]@{ status='pending'; updatedAtUtc=$null; message='' }
        }
    }
    Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'user' -Type 'task-created' -Summary "Task selected in $Mode mode for repositories $($selectedRepositoryIds -join ', '): $TaskSelector" -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}
elseif ($selectedRepositoryIds.Count) {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $previousIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) { @([string]$task.repositoryId) } else { @() }
    if (($previousIds -join '|') -ne (@($selectedRepositoryIds) -join '|')) {
        $task | Add-Member -NotePropertyName repositoryId -NotePropertyValue $selectedRepositoryIds[0] -Force
        $task | Add-Member -NotePropertyName repositoryIds -NotePropertyValue @($selectedRepositoryIds) -Force
        $task | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-Utf8NoBom -Path $taskPath -Content (($task | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
        & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor 'user' -Type 'workflow-status' -Summary "Repository scope updated: $($selectedRepositoryIds -join ', ')." -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    }
}
[pscustomobject]@{ TaskId = $TaskId; TaskRoot = $taskRoot; TaskPath = $taskPath; Resumed = [bool]$Resume; RepositoryIds=@($selectedRepositoryIds) }
