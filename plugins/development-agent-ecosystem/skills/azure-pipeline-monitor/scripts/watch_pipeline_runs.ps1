[CmdletBinding()]
param(
    [string]$Organization = 'https://dev.azure.com/Aucerna',
    [string]$Project = 'PlanningSpace',
    [string]$Branch,
    [string]$Commit,
    [int[]]$DefinitionIds = @(),
    [int[]]$AutoQueueDefinitionIds = @(),
    [datetime]$QueuedAfter = [datetime]::MinValue,
    [int]$DiscoveryTimeoutMinutes = 3,
    [int]$RunTimeoutMinutes = 60,
    [int]$PollSeconds = 20,
    [string]$AzCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($AzCli)) {
    $command = Get-Command az.cmd -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command az -ErrorAction SilentlyContinue
    }
    if ($null -eq $command) {
        $windowsAz = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        if (Test-Path -LiteralPath $windowsAz) {
            $AzCli = $windowsAz
        } else {
            throw 'Azure CLI was not found. Install Azure CLI and the azure-devops extension.'
        }
    } else {
        $AzCli = $command.Source
    }
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $output = & $AzCli @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join [Environment]::NewLine)"
    }

    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Could not resolve the current Git branch.'
    }
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Commit)) {
        throw 'Could not resolve the current Git commit.'
    }
}

$branchRef = if ($Branch.StartsWith('refs/heads/')) { $Branch } else { "refs/heads/$Branch" }
$queuedAfterUtc = if ($QueuedAfter -eq [datetime]::MinValue) {
    (Get-Date).ToUniversalTime().AddMinutes(-5)
} else {
    $QueuedAfter.ToUniversalTime()
}

Write-Host "Monitoring Azure pipelines for $branchRef at $Commit"
Write-Host "Queued after: $($queuedAfterUtc.ToString('o'))"

$expectedDefinitionIds = @($DefinitionIds + $AutoQueueDefinitionIds | Sort-Object -Unique)
$filterDefinitionIds = @()
if ($DefinitionIds.Count -gt 0) {
    $filterDefinitionIds = @($expectedDefinitionIds)
}
$queuedDefinitions = @{}
$tracked = @{}
$discoveryDeadline = (Get-Date).ToUniversalTime().AddMinutes($DiscoveryTimeoutMinutes)
$lastCount = -1
$stablePasses = 0

do {
    $runResult = Invoke-AzJson @(
        'pipelines', 'runs', 'list',
        '--organization', $Organization,
        '--project', $Project,
        '--branch', $branchRef,
        '--top', '100',
        '--output', 'json'
    )
    $runs = if ($runResult -is [array]) { @($runResult.GetEnumerator()) } else { @($runResult) }
    Write-Verbose "Azure returned $($runs.Count) run(s) for $branchRef."

    foreach ($run in $runs) {
        Write-Verbose "Candidate run $($run.id): commit=$($run.sourceVersion), definition=$($run.definition.id), queued=$($run.queueTime)"
        if ($null -eq $run -or $run.sourceVersion -ne $Commit) {
            continue
        }
        if ([datetime]::Parse($run.queueTime).ToUniversalTime() -lt $queuedAfterUtc) {
            continue
        }
        $definitionId = [int]$run.definition.id
        if ($filterDefinitionIds.Count -gt 0 -and $definitionId -notin $filterDefinitionIds) {
            continue
        }
        $tracked[[string]$run.id] = $run
    }

    $foundDefinitionIds = @($tracked.Values | ForEach-Object { [int]$_.definition.id } | Sort-Object -Unique)
    $missingAutoQueueIds = @($AutoQueueDefinitionIds | Where-Object {
        $_ -notin $foundDefinitionIds -and -not $queuedDefinitions.ContainsKey([string]$_)
    })
    foreach ($definitionId in $missingAutoQueueIds) {
        Write-Host "No run exists for definition $definitionId at $Commit; queueing it for $branchRef."
        $queuedRun = Invoke-AzJson @(
            'pipelines', 'run',
            '--id', [string]$definitionId,
            '--branch', ($branchRef -replace '^refs/heads/', ''),
            '--organization', $Organization,
            '--project', $Project,
            '--output', 'json'
        )
        $queuedDefinitions[[string]$definitionId] = $true
        Write-Host "Queued run $($queuedRun.id) for definition $definitionId."
    }

    if ($tracked.Count -eq $lastCount -and $tracked.Count -gt 0) {
        $stablePasses++
    } else {
        $stablePasses = 0
        $lastCount = $tracked.Count
    }

    $foundDefinitionIds = @($tracked.Values | ForEach-Object { [int]$_.definition.id } | Sort-Object -Unique)
    $missingDefinitionIds = @($expectedDefinitionIds | Where-Object { $_ -notin $foundDefinitionIds })
    if ($expectedDefinitionIds.Count -gt 0 -and $missingDefinitionIds.Count -eq 0 -and $stablePasses -ge 1) {
        break
    }
    if ($expectedDefinitionIds.Count -eq 0 -and $stablePasses -ge 1) {
        break
    }
    if ((Get-Date).ToUniversalTime() -ge $discoveryDeadline) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
} while ($true)

if ($tracked.Count -eq 0) {
    Write-Error "No pipeline runs were triggered for commit $Commit on $branchRef."
    exit 2
}

if ($expectedDefinitionIds.Count -gt 0) {
    $foundDefinitionIds = @($tracked.Values | ForEach-Object { [int]$_.definition.id } | Sort-Object -Unique)
    $missingDefinitionIds = @($expectedDefinitionIds | Where-Object { $_ -notin $foundDefinitionIds })
    if ($missingDefinitionIds.Count -gt 0) {
        Write-Error "No matching run was found for pipeline definition(s): $($missingDefinitionIds -join ', ')."
        exit 2
    }
}

Write-Host "Discovered $($tracked.Count) matching run(s):"
foreach ($run in $tracked.Values | Sort-Object id) {
    $url = "$Organization/$Project/_build/results?buildId=$($run.id)&view=results"
    Write-Host "  $($run.id) [$($run.definition.id)] $($run.definition.name): $url"
}

$deadline = (Get-Date).ToUniversalTime().AddMinutes($RunTimeoutMinutes)
$lastState = @{}
$completed = @{}

do {
    foreach ($runId in @($tracked.Keys)) {
        if ($completed.ContainsKey($runId)) {
            continue
        }

        $run = Invoke-AzJson @(
            'pipelines', 'runs', 'show',
            '--id', $runId,
            '--organization', $Organization,
            '--project', $Project,
            '--output', 'json'
        )
        $state = "$($run.status)/$($run.result)"
        if (-not $lastState.ContainsKey($runId) -or $lastState[$runId] -ne $state) {
            Write-Host "Run $runId [$($run.definition.id)] $($run.definition.name): $state"
            $lastState[$runId] = $state
        }
        if ($run.status -eq 'completed') {
            $completed[$runId] = $run
        }
    }

    if ($completed.Count -eq $tracked.Count) {
        break
    }
    if ((Get-Date).ToUniversalTime() -ge $deadline) {
        Write-Error "Timed out waiting for pipeline runs: $(@($tracked.Keys | Where-Object { -not $completed.ContainsKey($_) }) -join ', ')."
        exit 3
    }

    Start-Sleep -Seconds $PollSeconds
} while ($true)

$hasFailure = $false
foreach ($run in $completed.Values | Sort-Object id) {
    if ($run.result -eq 'succeeded') {
        continue
    }

    $hasFailure = $true
    Write-Host "Failed run $($run.id): result=$($run.result)" -ForegroundColor Red
    $timeline = Invoke-AzJson @(
        'devops', 'invoke',
        '--organization', $Organization,
        '--area', 'build',
        '--resource', 'timeline',
        '--route-parameters', "project=$Project", "buildId=$($run.id)",
        '--api-version', '7.1',
        '--output', 'json'
    )

    $failedTasks = @($timeline.records | Where-Object { $_.type -eq 'Task' -and $_.result -eq 'failed' })
    foreach ($task in $failedTasks) {
        Write-Host "Task: $($task.name)"
        if ($null -eq $task.log -or $null -eq $task.log.id) {
            continue
        }
        $logFile = Join-Path $env:TEMP "azdo-$($run.id)-$($task.log.id).log"
        & $AzCli devops invoke `
            --organization $Organization `
            --area build `
            --resource logs `
            --route-parameters "project=$Project" "buildId=$($run.id)" "logId=$($task.log.id)" `
            --api-version 7.1 `
            --accept-media-type text/plain `
            --out-file $logFile | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $logFile)) {
            Get-Content -LiteralPath $logFile -Tail 120
        }
    }
}

if ($hasFailure) {
    exit 1
}

Write-Host 'All matching pipeline runs succeeded.' -ForegroundColor Green
exit 0