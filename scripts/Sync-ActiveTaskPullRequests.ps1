[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$lockPath = Join-Path $stateRoot 'pr-lifecycle-sync.lock'
try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch { return [pscustomobject]@{ Status='busy'; Message='Another PR lifecycle sync is already running.' } }
try {
    $tasks = & (Join-Path $PSScriptRoot 'Get-AgentTasks.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($task in @($tasks.Tasks)) {
        if ([string]$task.status -eq 'completed') { continue }
        $taskRoot = Join-Path $stateRoot "tasks\$([string]$task.taskId)"
        $pipelinePath = Join-Path $taskRoot 'pipeline-result.json'
        $deliveryPath = Join-Path $taskRoot 'delivery-result.json'
        if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf) -or -not (Test-Path -LiteralPath $deliveryPath -PathType Leaf)) { continue }
        $delivery = $null
        try {
            $pipeline = Get-Content -LiteralPath $pipelinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $delivery = Get-Content -LiteralPath $deliveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$pipeline.overallResult -ne 'succeeded') { continue }
            $sync = & (Join-Path $PSScriptRoot 'Sync-TaskPullRequestStatus.ps1') -TaskId ([string]$task.taskId) -RepositoryId ([string]$delivery.repositoryId) -ConfigPath $ConfigPath -CodexHome $CodexHome
            $syncResult = if ($sync.PSObject.Properties['Result']) { $sync.Result } else { $null }
            $entries.Add([pscustomobject][ordered]@{ taskId=[string]$task.taskId; repositoryId=[string]$delivery.repositoryId; branch=[string]$delivery.branch; status=[string]$sync.Status; result=$syncResult; error=$null })
        }
        catch {
            $entries.Add([pscustomobject][ordered]@{ taskId=[string]$task.taskId; repositoryId=if ($delivery) { [string]$delivery.repositoryId } else { $null }; branch=if ($delivery) { [string]$delivery.branch } else { $null }; status='error'; result=$null; error=$_.Exception.Message })
        }
    }
    $index = [pscustomobject][ordered]@{ generatedAtUtc=[DateTime]::UtcNow.ToString('o'); pollIntervalMinutes=[int]$config.pipeline.pullRequests.pollIntervalMinutes; entries=@($entries) }
    $indexPath = Join-Path $stateRoot 'pr-lifecycle-index.json'
    Write-Utf8NoBom -Path $indexPath -Content (($index | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    [pscustomobject]@{ Status='completed'; IndexPath=$indexPath; Entries=@($entries) }
}
finally { $lock.Dispose() }
