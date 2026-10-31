[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $root '.test-task-config-binding-runtime'
if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
New-Item -ItemType Directory -Path $runtime -Force | Out-Null

try {
    $base = Get-Content -LiteralPath (Join-Path $root 'config\agents.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $project = @($base.projects | Where-Object { $_.enabled -and @($_.repositoryIds).Count -ge 2 }) | Select-Object -First 1
    if (-not $project) { throw 'Focused binding test requires one enabled project with at least two repositories.' }
    $repositoryIds = @([string]$project.repositoryIds[1], [string]$project.repositoryIds[0])
    $repositoryId = $repositoryIds[0]
    $taskId = 'binding-test-001'
    foreach ($name in @('a','b')) {
        $copy = $base | ConvertTo-Json -Depth 80 | ConvertFrom-Json
        $copy.runtime.stateRoot = (Join-Path $runtime 'state')
        foreach ($repository in @($copy.repositories)) {
            if ([string]$repository.id -in $repositoryIds) {
                $repository.localWorkspace = (Join-Path $runtime ("workspace-" + $name + '-' + [string]$repository.id))
                if ($name -eq 'a') { $repository.enabled = $false }
            }
        }
        $copy | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath (Join-Path $runtime "config-$name.json") -Encoding utf8NoBOM
    }
    $taskRoot = Join-Path $runtime "state\tasks\$taskId"
    New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
    [ordered]@{ taskId=$taskId; projectId=[string]$project.id; repositoryId=$repositoryId; repositoryIds=@($repositoryIds) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    $configA = Join-Path $runtime 'config-a.json'
    $configB = Join-Path $runtime 'config-b.json'
    $configBOriginal = Get-Content -LiteralPath $configB -Raw -Encoding UTF8
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $resolved = & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA
    if ([IO.Path]::GetFullPath($resolved.ConfigPath) -ne [IO.Path]::GetFullPath($configB)) { throw 'Bound task did not select configuration B when dashboard host configuration A shared state.' }
    $hostConfig = Get-Content -LiteralPath $configA -Raw | ConvertFrom-Json
    if (@($hostConfig.repositories | Where-Object { [string]$_.id -in $repositoryIds -and $_.enabled }).Count) { throw 'Host configuration fixture did not disable the task repositories.' }
    if (@($resolved.Config.repositories | Where-Object { [string]$_.id -in $repositoryIds -and $_.enabled }).Count -ne $repositoryIds.Count) { throw 'Bound task configuration does not keep all task repositories enabled for dispatch.' }
    if ([string]$resolved.Binding.workspaceRoot -ne [IO.Path]::GetFullPath((Join-Path $runtime ("workspace-b-" + $repositoryId)))) { throw 'Bound task did not preserve its owned workspace root.' }
    $bindingPath = Join-Path $taskRoot 'task-config-binding.json'
    if ((@($resolved.Binding.repositoryIds | ForEach-Object { [string]$_ }) -join '|') -ne ($repositoryIds -join '|')) { throw 'Bound task did not preserve the caller-selected repository order.' }
    $alternateConfig = $configBOriginal | ConvertFrom-Json
    $alternateConfig.operation.mode = if ([string]$alternateConfig.operation.mode -eq 'manual') { 'automate' } else { 'manual' }
    $alternateConfig | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $configB -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Alternate bound configuration content mutation was accepted.' } catch { if ($_.Exception.Message -eq 'Alternate bound configuration content mutation was accepted.') { throw } }
    [IO.File]::WriteAllText($configB, $configBOriginal, [Text.UTF8Encoding]::new($false))
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $taskDocument = Get-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Raw | ConvertFrom-Json
    $taskDocument.PSObject.Properties.Remove('projectId')
    $taskDocument | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Bound task without project metadata was accepted.' } catch { if ($_.Exception.Message -eq 'Bound task without project metadata was accepted.') { throw } }
    [ordered]@{ taskId=$taskId; projectId=[string]$project.id; repositoryId=$repositoryId; repositoryIds=@($repositoryIds) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json
    $binding.sourceConfigSha256 = '0' * 64; $binding | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bindingPath -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Hash mutation was accepted.' } catch { if ($_.Exception.Message -eq 'Hash mutation was accepted.') { throw } }
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json; $binding.projectId = 'foreign-project'; $binding | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bindingPath -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Foreign project binding was accepted.' } catch { if ($_.Exception.Message -eq 'Foreign project binding was accepted.') { throw } }
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json; $binding.stateRoot = (Join-Path $runtime 'foreign-state'); $binding | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bindingPath -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Foreign state root was accepted.' } catch { if ($_.Exception.Message -eq 'Foreign state root was accepted.') { throw } }
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json; $binding.sourceConfigPath = (Join-Path $runtime 'missing.json'); $binding | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bindingPath -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Missing bound source was accepted.' } catch { if ($_.Exception.Message -eq 'Missing bound source was accepted.') { throw } }
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    Copy-Item -LiteralPath $configB -Destination (Join-Path $taskRoot 'execution-config-old.json')
    $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json; $binding.sourceConfigPath = (Join-Path $taskRoot 'execution-config-old.json'); $binding.sourceConfigSha256 = (Get-FileHash -LiteralPath $binding.sourceConfigPath -Algorithm SHA256).Hash.ToLowerInvariant(); $binding | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $bindingPath -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Execution snapshot was accepted.' } catch { if ($_.Exception.Message -eq 'Execution snapshot was accepted.') { throw } }
    $hostConfig = Get-Content -LiteralPath $configA -Raw | ConvertFrom-Json
    foreach ($repository in @($hostConfig.repositories | Where-Object { [string]$_.id -in $repositoryIds })) { $repository.enabled = $true }
    $hostConfig | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $configA -Encoding utf8NoBOM
    Remove-Item -LiteralPath $bindingPath -Force
    [ordered]@{ taskId=$taskId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    $legacy = & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA
    if (-not $legacy.IsLegacy -or [IO.Path]::GetFullPath($legacy.ConfigPath) -ne [IO.Path]::GetFullPath($configA)) { throw 'Valid legacy task did not fall back to host configuration.' }
    [ordered]@{ taskId=$taskId; projectId=[string]$project.id; repositoryId=$repositoryId; repositoryIds=@($repositoryIds) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    $taskDocument = Get-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Raw | ConvertFrom-Json
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configB | Out-Null
    $taskDocument.repositoryIds = @($repositoryIds + @('missing-repository'))
    $taskDocument | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Foreign repository scope was accepted.' } catch { if ($_.Exception.Message -eq 'Foreign repository scope was accepted.') { throw } }
    [ordered]@{ taskId=$taskId; projectId=[string]$project.id; repositoryId=$repositoryId; repositoryIds=@($repositoryIds) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Encoding utf8NoBOM
    & (Join-Path $root 'scripts\Write-TaskConfigBinding.ps1') -TaskId $taskId -ConfigPath $configA | Out-Null
    $hostConfig = Get-Content -LiteralPath $configA -Raw | ConvertFrom-Json
    $hostConfig.operation.mode = if ([string]$hostConfig.operation.mode -eq 'manual') { 'automate' } else { 'manual' }
    $hostConfig | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $configA -Encoding utf8NoBOM
    $hostRefresh = & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA
    if (-not $hostRefresh.HostConfigRefreshed -or [IO.Path]::GetFullPath($hostRefresh.ConfigPath) -ne [IO.Path]::GetFullPath($configA)) { throw 'A legitimate trusted-host configuration reload was rejected.' }
    $hostConfig = Get-Content -LiteralPath $configA -Raw | ConvertFrom-Json
    (@($hostConfig.repositories | Where-Object { [string]$_.id -eq $repositoryId })[0]).localWorkspace = (Join-Path $runtime 'host-workspace-identity-changed')
    $hostConfig | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $configA -Encoding utf8NoBOM
    try { & (Join-Path $root 'scripts\Resolve-TaskLaunchConfig.ps1') -TaskId $taskId -HostConfigPath $configA | Out-Null; throw 'Trusted-host workspace identity mutation was accepted.' } catch { if ($_.Exception.Message -eq 'Trusted-host workspace identity mutation was accepted.') { throw } }
    $dashboard = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw
    if ($dashboard -match 'body\.configPath|body\[''configPath''\]') { throw 'Dashboard accepts a request-body configuration path.' }
    if (@([regex]::Matches($dashboard, 'Resolve-TaskLaunchConfig\.ps1')).Count -lt 3) { throw 'Dashboard does not resolve the task-bound configuration for normal, targeted, and elevated resume routes.' }
    if (-not $dashboard.Contains("Get-AgentResumePlan.ps1') -TaskId `$resolvedTaskId -ConfigPath ([string]`$launchConfig.ConfigPath)") -or -not $dashboard.Contains("Get-AgentResumePlan.ps1') -TaskId `$requestedTaskId -ConfigPath ([string]`$launchConfig.ConfigPath)")) { throw 'Dashboard resume plans do not use the task-bound configuration.' }
    $normalResolve = $dashboard.IndexOf("Resolve-TaskLaunchConfig.ps1') -TaskId `$resolvedTaskId")
    $normalValidation = $dashboard.IndexOf('Get-EnabledRepositories -Config $launchConfig.Config -RepositoryIds $repositoryIds', $normalResolve)
    $elevatedResolve = $dashboard.IndexOf("Resolve-TaskLaunchConfig.ps1') -TaskId `$requestedTaskId")
    $elevatedValidation = $dashboard.IndexOf('Get-EnabledRepositories -Config $launchConfig.Config -RepositoryIds $repositoryIds', $elevatedResolve)
    if ($normalResolve -lt 0 -or $normalValidation -lt $normalResolve -or $elevatedResolve -lt 0 -or $elevatedValidation -lt $elevatedResolve) { throw 'Dashboard validates a resume repository with host configuration before resolving the task-bound configuration.' }
    if (-not $dashboard.Contains("Set-AgentTaskStatus.ps1') -TaskId `$TaskId -AgentId `$AgentId") -or -not $dashboard.Contains('-ConfigPath ([string]$launchConfig.ConfigPath) -CodexHome $CodexHome | Out-Null') -or -not $dashboard.Contains("Targeted restart requested for '`$AgentId'.")) { throw 'Targeted resume does not use the bound configuration for its status/event writes.' }
    $elevatedEvent = "Summary 'Elevated workflow resume requested from the dashboard.' -Artifact `$taskPath -TargetAgentId orchestrator -ConfigPath ([string]`$launchConfig.ConfigPath)"
    if (-not $dashboard.Contains($elevatedEvent)) { throw 'Elevated resume event does not use the bound configuration.' }
    $healthResolve = $dashboard.IndexOf("Resolve-TaskLaunchConfig.ps1') -TaskId `$requestedTaskId -HostConfigPath `$ConfigPath", $dashboard.IndexOf("health-recovery/elevated"))
    $healthPolicy = $dashboard.IndexOf('if (-not [bool]$launchConfig.Config.health.automaticRecovery.elevatedFallback.enabled)', $healthResolve)
    $healthLaunch = $dashboard.IndexOf("Start-AgentHealthRecovery.ps1') -TaskId `$requestedTaskId", $healthResolve)
    if ($healthResolve -lt 0 -or $healthPolicy -lt $healthResolve -or $healthLaunch -lt $healthPolicy -or -not $dashboard.Substring($healthLaunch, [Math]::Min(400, $dashboard.Length - $healthLaunch)).Contains('ConfigPath=[string]$launchConfig.ConfigPath')) { throw 'Elevated health recovery does not resolve and use the bound task configuration before policy and launch.' }
    'PASS: bound dashboard resume selects task configuration B, rejects tampering/snapshots, and legacy fallback remains host-only.'
}
finally {
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
}
