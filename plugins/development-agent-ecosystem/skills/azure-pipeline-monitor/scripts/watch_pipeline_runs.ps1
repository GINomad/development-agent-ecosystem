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
    [switch]$LatestRunPerDefinition,
    [string]$AzCli,
    [string]$TaskId = 'pipeline-monitor',
    [string]$RepositoryId = 'unknown',
    [string]$ResultPath,
    [string]$ClassifierScript,
    [ValidateRange(20,500)][int]$FailureLogTailLines = 120,
    [ValidateRange(4096,262144)][int]$FailureLogMaxBytes = 65536,
    [ValidateRange(0,3)][int]$RemediationCycle = 0,
    [ValidateRange(1,3)][int]$MaxRemediationCycles = 3,
    [ValidateRange(1,600)][int]$ProgressHeartbeatSeconds = 60,
    [scriptblock]$ProgressCallback,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$progressState = @{ LastAt = [DateTime]::MinValue; LastStage = $null }

function Send-MonitorProgress {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Summary,
        [string]$Details,
        [switch]$Force
    )
    if (-not $ProgressCallback) { return }
    $now = [DateTime]::UtcNow
    $due = ($now - [datetime]$progressState.LastAt).TotalSeconds -ge $ProgressHeartbeatSeconds
    if ($Force -or $progressState.LastStage -ne $Stage -or $due) {
        & $ProgressCallback $Stage $Summary $Details
        $progressState.LastAt = $now
        $progressState.LastStage = $Stage
    }
}

if ([string]::IsNullOrWhiteSpace($AzCli)) {
    $command = Get-Command az.cmd -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command az -ErrorAction SilentlyContinue }
    if ($null -eq $command) {
        $windowsAz = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
        if (Test-Path -LiteralPath $windowsAz) { $AzCli = $windowsAz }
        else { throw 'Azure CLI was not found. Install Azure CLI and the azure-devops extension.' }
    }
    else { $AzCli = $command.Source }
}
if (-not $ClassifierScript) {
    $ClassifierScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\..\scripts\Classify-PipelineFailure.ps1'))
}
if (-not (Test-Path -LiteralPath $ClassifierScript -PathType Leaf)) { throw "Pipeline failure classifier was not found: $ClassifierScript" }

function Invoke-AzJson {
    param([string[]]$Arguments)
    $output = & $AzCli @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($output -join [Environment]::NewLine)" }
    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Get-BoundedLogExcerpt {
    param([string[]]$Lines, [int]$MaximumBytes)
    $selected = [Collections.Generic.List[string]]::new()
    $byteCount = 0
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($index = $Lines.Count - 1; $index -ge 0; $index--) {
        $line = [string]$Lines[$index]
        $lineBytes = $encoding.GetByteCount($line + [Environment]::NewLine)
        if ($selected.Count -gt 0 -and ($byteCount + $lineBytes) -gt $MaximumBytes) { break }
        $selected.Insert(0, $line)
        $byteCount += $lineBytes
    }
    return ($selected -join [Environment]::NewLine)
}

function Get-FailureSignature {
    param([string]$Value)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Value)
        return (($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $algorithm.Dispose() }
}

function New-PipelineResult {
    param(
        [object[]]$Runs,
        [ValidateSet('succeeded','non-success','no-run')][string]$OverallResult,
        $Classification,
        [int[]]$QueuedIds,
        [string]$Summary
    )
    $signature = $null
    if ($OverallResult -ne 'succeeded') {
        $signatureSource = @(
            $RepositoryId,
            $Branch,
            $Commit,
            [string]$Classification.category,
            @($Runs | ForEach-Object { @($_.failedTasks) | ForEach-Object { "$($_.name):$($_.category):$($_.logExcerpt)" } }) -join [Environment]::NewLine
        ) -join '|'
        $signature = Get-FailureSignature -Value $signatureSource
    }
    $nextCycle = [Math]::Min($RemediationCycle + 1, $MaxRemediationCycles)
    if ([bool]$Classification.developerEligible -and $RemediationCycle -lt $MaxRemediationCycles) {
        $remediationStatus = 'pending'
        $targetAgentId = 'developer'
        $reason = "A $($Classification.category) failure is eligible for a bounded Developer fix cycle."
    }
    elseif ([bool]$Classification.developerEligible) {
        $remediationStatus = 'limit-reached'
        $targetAgentId = $null
        $reason = "The maximum of $MaxRemediationCycles Developer remediation cycles has been reached."
    }
    else {
        $remediationStatus = 'not-applicable'
        $targetAgentId = $null
        $reason = if ($OverallResult -eq 'succeeded') { 'No remediation is required.' } else { "Failure category '$($Classification.category)' is not a product-code remediation." }
        $nextCycle = $RemediationCycle
    }
    [pscustomobject][ordered]@{
        taskId = $TaskId
        repositoryId = $RepositoryId
        observedAtUtc = [DateTime]::UtcNow.ToString('o')
        branch = $Branch
        commit = $Commit
        queuedDefinitionIds = @($QueuedIds)
        runs = @($Runs)
        overallResult = $OverallResult
        failureClassification = $Classification
        remediation = [pscustomobject][ordered]@{
            status = $remediationStatus
            cycle = $nextCycle
            maxCycles = $MaxRemediationCycles
            failureSignature = $signature
            targetAgentId = $targetAgentId
            reason = $reason
        }
        summary = $Summary
    }
}

function Write-PipelineResult {
    param($Result)
    if ($ResultPath) {
        $parent = Split-Path -Parent $ResultPath
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($ResultPath, (($Result | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    }
}

if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Branch)) { throw 'Could not resolve the current Git branch.' }
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Commit)) { throw 'Could not resolve the current Git commit.' }
}
if ($Commit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Commit must be a full 40-character SHA.' }

$branchRef = if ($Branch.StartsWith('refs/heads/')) { $Branch } else { "refs/heads/$Branch" }
$Branch = $branchRef -replace '^refs/heads/', ''
$queuedAfterUtc = if ($QueuedAfter -eq [datetime]::MinValue) { [DateTime]::UtcNow.AddMinutes(-5) } else { $QueuedAfter.ToUniversalTime() }
Write-Host "Monitoring Azure pipelines for $branchRef at $Commit"
Write-Host "Queued after: $($queuedAfterUtc.ToString('o'))"
Send-MonitorProgress -Stage pipeline_discovery -Summary "Discovering exact-SHA pipeline runs for $($Commit.Substring(0,12))." -Details "Branch: $Branch; queued after: $($queuedAfterUtc.ToString('o'))." -Force

$expectedDefinitionIds = @($DefinitionIds + $AutoQueueDefinitionIds | Sort-Object -Unique)
$passiveDefinitionIds = @($DefinitionIds | Where-Object { $_ -notin $AutoQueueDefinitionIds } | Sort-Object -Unique)
$queuedDefinitions = [Collections.Generic.List[int]]::new()
$tracked = @{}
$completed = @{}
$lastState = @{}
$sequenceSucceeded = $true

# Auto-queued definitions are an ordered, fail-closed sequence. The first stage may
# reuse a qualifying exact-SHA run; every later stage is deliberately queued only
# after the preceding selected run succeeds, so an earlier run cannot satisfy it.
for ($sequenceIndex = 0; $sequenceIndex -lt $AutoQueueDefinitionIds.Count; $sequenceIndex++) {
    $definitionId = [int]$AutoQueueDefinitionIds[$sequenceIndex]
    $selectedRun = $null
    if ($sequenceIndex -eq 0) {
        $runResult = Invoke-AzJson @('pipelines','runs','list','--organization',$Organization,'--project',$Project,'--branch',$branchRef,'--top','100','--output','json')
        $runs = if ($runResult -is [array]) { @($runResult.GetEnumerator()) } elseif ($null -eq $runResult) { @() } else { @($runResult) }
        $selectedRun = @($runs | Where-Object {
            $null -ne $_ -and [string]$_.sourceVersion -eq $Commit -and [int]$_.definition.id -eq $definitionId -and
            [datetime]::Parse([string]$_.queueTime).ToUniversalTime() -ge $queuedAfterUtc
        } | Sort-Object { [datetime]::Parse([string]$_.queueTime).ToUniversalTime() } -Descending | Select-Object -First 1)
        if ($selectedRun.Count -gt 0) { $selectedRun = $selectedRun[0] } else { $selectedRun = $null }
    }
    if ($null -eq $selectedRun) {
        Write-Host "Queueing approved build definition $definitionId at sequence position $($sequenceIndex + 1) for $branchRef."
        Send-MonitorProgress -Stage pipeline_queueing -Summary "Queueing approved definition $definitionId." -Details "Ordered position $($sequenceIndex + 1) of $($AutoQueueDefinitionIds.Count)." -Force
        $selectedRun = Invoke-AzJson @('pipelines','run','--id',[string]$definitionId,'--branch',$Branch,'--organization',$Organization,'--project',$Project,'--output','json')
        if ($null -eq $selectedRun -or $null -eq $selectedRun.id) { throw "Azure CLI did not return a run ID for definition $definitionId." }
        $queuedDefinitions.Add($definitionId)
        Write-Host "Queued run $($selectedRun.id) for build definition $definitionId."
        Send-MonitorProgress -Stage pipeline_waiting -Summary "Waiting for definition $definitionId run $($selectedRun.id)." -Details 'The native watcher is polling Azure DevOps without an AI turn.' -Force
    }

    $runId = [string]$selectedRun.id
    $runDeadline = [DateTime]::UtcNow.AddMinutes($RunTimeoutMinutes)
    do {
        $run = Invoke-AzJson @('pipelines','runs','show','--id',$runId,'--organization',$Organization,'--project',$Project,'--output','json')
        $state = "$($run.status)/$($run.result)"
        if (-not $lastState.ContainsKey($runId) -or $lastState[$runId] -ne $state) {
            Write-Host "Run $runId [$($run.definition.id)] $($run.definition.name): $state"
            $lastState[$runId] = $state
            Send-MonitorProgress -Stage pipeline_waiting -Summary "Definition $definitionId run $runId is $state." -Details ([string]$run.definition.name) -Force
        }
        else {
            Send-MonitorProgress -Stage pipeline_waiting -Summary "Still waiting for definition $definitionId run $runId." -Details "Current Azure state: $state."
        }
        if ([string]$run.status -eq 'completed') { break }
        if ([DateTime]::UtcNow -ge $runDeadline) {
            $timedOutRun = [pscustomobject][ordered]@{
                id=[int]$selectedRun.id; definitionId=$definitionId; definitionName=[string]$selectedRun.definition.name
                url="$Organization/$Project/_build/results?buildId=$($selectedRun.id)&view=results"; sourceVersion=$Commit
                result='timedOut'; failedTasks=@(); failedLogExcerpts=@()
            }
            $classification = [pscustomobject]@{ category='infrastructure'; developerEligible=$false; matchedSignals=@('Pipeline monitoring timed out') }
            $result = New-PipelineResult -Runs @($timedOutRun) -OverallResult non-success -Classification $classification -QueuedIds @($queuedDefinitions) -Summary "Timed out waiting for ordered exact-SHA definition $definitionId."
            Write-PipelineResult -Result $result
            if ($PassThru) { return $result }
            Write-Error -ErrorAction Continue $result.summary
            exit 3
        }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)

    if ([int]$run.definition.id -ne $definitionId -or [string]$run.sourceVersion -ne $Commit) {
        throw "Ordered pipeline run $runId did not match definition $definitionId and exact commit $Commit."
    }
    $tracked[$runId] = $run
    $completed[$runId] = $run
    if ([string]$run.result -ne 'succeeded') {
        $sequenceSucceeded = $false
        Write-Host "Definition $definitionId did not succeed; later ordered definitions will not be queued." -ForegroundColor Red
        break
    }
}

# Observe configured non-auto-queued definitions after the ordered sequence. When
# no definitions are configured, preserve the existing behavior of observing all
# exact-SHA runs without queueing anything.
$discoverPassiveRuns = $sequenceSucceeded -and ($passiveDefinitionIds.Count -gt 0 -or $expectedDefinitionIds.Count -eq 0)
if ($discoverPassiveRuns) {
    $discoveryDeadline = [DateTime]::UtcNow.AddMinutes($DiscoveryTimeoutMinutes)
    $lastCount = -1
    $stablePasses = 0
    do {
        Send-MonitorProgress -Stage pipeline_discovery -Summary 'Discovering configured exact-SHA pipeline runs.' -Details "Tracked runs: $($tracked.Count)."
        $runResult = Invoke-AzJson @('pipelines','runs','list','--organization',$Organization,'--project',$Project,'--branch',$branchRef,'--top','100','--output','json')
        $runs = if ($runResult -is [array]) { @($runResult.GetEnumerator()) } elseif ($null -eq $runResult) { @() } else { @($runResult) }
        $matchingRuns = @($runs | Where-Object {
            $null -ne $_ -and [string]$_.sourceVersion -eq $Commit -and
            [datetime]::Parse([string]$_.queueTime).ToUniversalTime() -ge $queuedAfterUtc -and
            ($passiveDefinitionIds.Count -eq 0 -or [int]$_.definition.id -in $passiveDefinitionIds)
        })
        if ($LatestRunPerDefinition) {
            $matchingRuns = @($matchingRuns | Group-Object { [int]$_.definition.id } | ForEach-Object {
                @($_.Group | Sort-Object { [datetime]::Parse([string]$_.queueTime).ToUniversalTime() } -Descending | Select-Object -First 1)
            })
        }
        foreach ($run in $matchingRuns) {
            $definitionId = [int]$run.definition.id
            $tracked[[string]$run.id] = $run
        }
        $passiveRuns = @($tracked.Values | Where-Object { $passiveDefinitionIds.Count -eq 0 -or [int]$_.definition.id -in $passiveDefinitionIds })
        if ($passiveRuns.Count -eq $lastCount -and $passiveRuns.Count -gt 0) { $stablePasses++ }
        else { $stablePasses = 0; $lastCount = $passiveRuns.Count }
        $foundDefinitionIds = @($passiveRuns | ForEach-Object { [int]$_.definition.id } | Sort-Object -Unique)
        $missingDefinitionIds = @($passiveDefinitionIds | Where-Object { $_ -notin $foundDefinitionIds })
        if ($passiveDefinitionIds.Count -gt 0 -and $missingDefinitionIds.Count -eq 0 -and $stablePasses -ge 1) { break }
        if ($passiveDefinitionIds.Count -eq 0 -and $stablePasses -ge 1) { break }
        if ([DateTime]::UtcNow -ge $discoveryDeadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
}

if ($tracked.Count -eq 0) {
    $classification = [pscustomobject]@{ category='unknown'; developerEligible=$false; matchedSignals=@() }
    $result = New-PipelineResult -Runs @() -OverallResult no-run -Classification $classification -QueuedIds @($queuedDefinitions) -Summary "No exact-SHA pipeline run was found for $Branch@$Commit."
    Write-PipelineResult -Result $result
    if ($PassThru) { return $result }
    Write-Error -ErrorAction Continue $result.summary
    exit 2
}
if ($sequenceSucceeded -and $passiveDefinitionIds.Count -gt 0) {
    $foundDefinitionIds = @($tracked.Values | ForEach-Object { [int]$_.definition.id } | Sort-Object -Unique)
    $missingDefinitionIds = @($passiveDefinitionIds | Where-Object { $_ -notin $foundDefinitionIds })
    if ($missingDefinitionIds.Count -gt 0) {
        $classification = [pscustomobject]@{ category='unknown'; developerEligible=$false; matchedSignals=@() }
        $result = New-PipelineResult -Runs @() -OverallResult no-run -Classification $classification -QueuedIds @($queuedDefinitions) -Summary "No exact-SHA run was found for definition(s): $($missingDefinitionIds -join ', ')."
        Write-PipelineResult -Result $result
        if ($PassThru) { return $result }
        Write-Error -ErrorAction Continue $result.summary
        exit 2
    }
}

Write-Host "Discovered $($tracked.Count) matching run(s)."
$deadline = [DateTime]::UtcNow.AddMinutes($RunTimeoutMinutes)
do {
    foreach ($runId in @($tracked.Keys)) {
        if ($completed.ContainsKey($runId)) { continue }
        $run = Invoke-AzJson @('pipelines','runs','show','--id',$runId,'--organization',$Organization,'--project',$Project,'--output','json')
        $state = "$($run.status)/$($run.result)"
        if (-not $lastState.ContainsKey($runId) -or $lastState[$runId] -ne $state) {
            Write-Host "Run $runId [$($run.definition.id)] $($run.definition.name): $state"
            $lastState[$runId] = $state
            Send-MonitorProgress -Stage pipeline_waiting -Summary "Pipeline run $runId is $state." -Details ([string]$run.definition.name) -Force
        }
        else {
            Send-MonitorProgress -Stage pipeline_waiting -Summary "Still waiting for pipeline run $runId." -Details "Current Azure state: $state."
        }
        if ([string]$run.status -eq 'completed') { $completed[$runId] = $run }
    }
    if ($completed.Count -eq $tracked.Count) { break }
    if ([DateTime]::UtcNow -ge $deadline) {
        $timedOutRuns = [Collections.Generic.List[object]]::new()
        foreach ($trackedRun in $tracked.Values | Sort-Object id) {
            $timedOutRuns.Add([pscustomobject][ordered]@{
                id=[int]$trackedRun.id; definitionId=[int]$trackedRun.definition.id; definitionName=[string]$trackedRun.definition.name
                url="$Organization/$Project/_build/results?buildId=$($trackedRun.id)&view=results"; sourceVersion=[string]$trackedRun.sourceVersion
                result='timedOut'; failedTasks=@(); failedLogExcerpts=@()
            })
        }
        $classification = [pscustomobject]@{ category='infrastructure'; developerEligible=$false; matchedSignals=@('Pipeline monitoring timed out') }
        $result = New-PipelineResult -Runs @($timedOutRuns) -OverallResult non-success -Classification $classification -QueuedIds @($queuedDefinitions) -Summary 'Timed out waiting for exact-SHA pipeline runs.'
        Write-PipelineResult -Result $result
        if ($PassThru) { return $result }
        Write-Error -ErrorAction Continue $result.summary
        exit 3
    }
    Start-Sleep -Seconds $PollSeconds
} while ($true)

$structuredRuns = [Collections.Generic.List[object]]::new()
$allSignals = [Collections.Generic.List[string]]::new()
$allCategories = [Collections.Generic.List[string]]::new()
foreach ($run in $completed.Values | Sort-Object id) {
    $failedTasks = [Collections.Generic.List[object]]::new()
    $failedLogExcerpts = [Collections.Generic.List[string]]::new()
    $runResult = [string]$run.result
    if ($runResult -notin @('succeeded','failed','partiallySucceeded','canceled')) { $runResult = 'failed' }
    if ($runResult -ne 'succeeded') {
        Write-Host "Non-success run $($run.id): result=$runResult" -ForegroundColor Red
        Send-MonitorProgress -Stage pipeline_failure_analysis -Summary "Analyzing failed tasks for run $($run.id)." -Details "Definition $($run.definition.id); result: $runResult." -Force
        $timeline = Invoke-AzJson @('devops','invoke','--organization',$Organization,'--area','build','--resource','timeline','--route-parameters',"project=$Project","buildId=$($run.id)",'--api-version','7.1','--output','json')
        foreach ($task in @($timeline.records | Where-Object { [string]$_.type -eq 'Task' -and [string]$_.result -eq 'failed' })) {
            $excerpt = ''
            if ($null -ne $task.log -and $null -ne $task.log.id) {
                $logFile = Join-Path ([IO.Path]::GetTempPath()) "azdo-$($run.id)-$($task.log.id)-$([guid]::NewGuid().ToString('N')).log"
                try {
                    $logDownloadOutput = @(& $AzCli devops invoke --organization $Organization --area build --resource logs --route-parameters "project=$Project" "buildId=$($run.id)" "logId=$($task.log.id)" --api-version 7.1 --accept-media-type text/plain --out-file $logFile 2>&1)
                    $logDownloadExitCode = $LASTEXITCODE
                    if ($logDownloadExitCode -eq 0 -and (Test-Path -LiteralPath $logFile -PathType Leaf)) {
                        $tail = @(Get-Content -LiteralPath $logFile -Tail $FailureLogTailLines -Encoding UTF8)
                        $excerpt = Get-BoundedLogExcerpt -Lines $tail -MaximumBytes $FailureLogMaxBytes
                        Write-Host $excerpt
                    }
                    else {
                        Write-Warning "Unable to download Azure log $($task.log.id) for run $($run.id): $($logDownloadOutput -join [Environment]::NewLine)"
                    }
                }
                finally {
                    if (Test-Path -LiteralPath $logFile -PathType Leaf) { Remove-Item -LiteralPath $logFile -Force }
                }
            }
            $taskClassification = & $ClassifierScript -TaskNames @([string]$task.name) -LogLines @($excerpt -split '\r?\n')
            $allCategories.Add([string]$taskClassification.category)
            foreach ($signal in @($taskClassification.matchedSignals)) { if ($allSignals.Count -lt 8) { $allSignals.Add([string]$signal) } }
            $failedTasks.Add([pscustomobject][ordered]@{ name=[string]$task.name; category=[string]$taskClassification.category; logExcerpt=$excerpt })
            if ($excerpt) { $failedLogExcerpts.Add($excerpt) }
        }
        if ($failedTasks.Count -eq 0) { $allCategories.Add('unknown') }
    }
    $structuredRuns.Add([pscustomobject][ordered]@{
        id=[int]$run.id; definitionId=[int]$run.definition.id; definitionName=[string]$run.definition.name
        url="$Organization/$Project/_build/results?buildId=$($run.id)&view=results"; sourceVersion=[string]$run.sourceVersion
        result=$runResult; failedTasks=@($failedTasks); failedLogExcerpts=@($failedLogExcerpts)
    })
}

$hasNonSuccess = @($structuredRuns | Where-Object { [string]$_.result -ne 'succeeded' }).Count -gt 0
if (-not $hasNonSuccess) {
    $classification = [pscustomobject]@{ category='none'; developerEligible=$false; matchedSignals=@() }
    $overallResult = 'succeeded'
    $summary = "All exact-SHA pipeline runs succeeded for $Branch@$Commit."
}
else {
    $category = if (@($allCategories) -contains 'test') { 'test' } elseif (@($allCategories) -contains 'code') { 'code' } elseif (@($allCategories) -contains 'infrastructure') { 'infrastructure' } else { 'unknown' }
    $classification = [pscustomobject]@{ category=$category; developerEligible=$category -in @('code','test'); matchedSignals=@($allSignals) }
    $overallResult = 'non-success'
    $summary = "Exact-SHA pipeline completed with non-success; classified as $category."
}
$result = New-PipelineResult -Runs @($structuredRuns) -OverallResult $overallResult -Classification $classification -QueuedIds @($queuedDefinitions) -Summary $summary
Write-PipelineResult -Result $result
Send-MonitorProgress -Stage pipeline_terminal -Summary $summary -Details "Overall result: $overallResult." -Force
if ($PassThru) { return $result }
if ($overallResult -ne 'succeeded') { exit 1 }
Write-Host 'All matching pipeline runs succeeded.' -ForegroundColor Green
exit 0
