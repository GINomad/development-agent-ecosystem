[CmdletBinding()]
param(
    [string] $ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome,
    [string] $OutputPath,
    [ValidateRange(1,10000)][int] $MaxLinesPerFile=10000
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot=Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
function Field($Object,[string]$Name,$Default=$null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Read-Json([string]$Path) {
    try { if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -le 1048576) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
}
function Read-Tail([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $MaxLinesPerFile }
}
function Count-Category($Map,[string]$Key) { if (-not $Map.Contains($Key)) { $Map[$Key]=0 }; $Map[$Key]++ }
function Percentile([double[]]$Values,[double]$Fraction) {
    if ($Values.Count -eq 0) { return $null }
    $sorted=@($Values|Sort-Object)
    return $sorted[[int][Math]::Ceiling($Fraction*$sorted.Count)-1]
}
$active=[ordered]@{}; $historical=[ordered]@{}; $missingRun=0; $missingAttempt=0; $failureCount=0
$cohorts=@{}; $bundles=[ordered]@{}; $metricLines=0; $sparse=0; $malformed=0; $duplicates=0; $nonterminal=0
$resumes=@{}; $conflicted=@{}; $uncorrelated=0; $conflicting=0
$tasksRoot=Join-Path $stateRoot 'tasks'
foreach ($taskDir in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -ErrorAction SilentlyContinue)) {
    $task=Read-Json (Join-Path $taskDir.FullName 'task.json')
    foreach ($file in @(Get-ChildItem -LiteralPath $taskDir.FullName -Filter 'agent-failure-*.json' -File)) {
        $failure=Read-Json $file.FullName
        if (-not $failure) { continue }
        $failureCount++
        if (-not (Field $failure executionRunId)) { $missingRun++ }
        if (-not (Field $failure executionAttemptId)) { $missingAttempt++ }
        $bucket=$active
        if ((Field $failure disposition) -in @('stale-superseded','resolved') -or (Field $task status) -eq 'completed') { $bucket=$historical }
        $text=([string](Field $failure summary '')+' '+[string](Field $failure error ''))
        $classification=& (Join-Path $PSScriptRoot 'Get-ProviderFailureClassification.ps1') -Diagnostic $text
        $category='unclassified'
        if ($classification.IsExternal) { $category=[string]$classification.Category }
        elseif ($text -match '(?i)\bhold\b|conflict|acceptance|already has an active controller|stale.*review|review.*gate') { $category='expected-hold-conflict' }
        elseif ($text -match '(?i)ecosystem|workspace-coordinator|SourceKind|semantic validator|knowledge-usage|publication.*schema|MCP.*(?:range|protocol)') { $category='control-plane' }
        elseif ($text -match '(?i)\bbuild\s+(?:failed|failure)|compiler|product.*failure') { $category='product' }
        Count-Category $bucket $category
    }
    foreach ($line in @(Read-Tail (Join-Path $taskDir.FullName 'role-metrics.jsonl'))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $metric=$line|ConvertFrom-Json -ErrorAction Stop } catch { $malformed++; continue }
        $metricLines++
        if ((Field $metric eventType) -ne 'role-attempt-completed') { $nonterminal++; continue }
        $ids=@([string](Field $metric taskId ''),[string](Field $metric runId ''),[string](Field $metric attemptId ''))
        if (@($ids|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count -or (Field $metric status) -notin @('succeeded','failed')) { $sparse++; continue }
        $key=$ids|ConvertTo-Json -Compress
        if ($cohorts.ContainsKey($key)) { $duplicates++; continue }
        $cohorts[$key]=$metric
        $bundle=[string](Field $metric executionBundleFingerprint (Field $metric executionBundleManifestSha256 'unattributed'))
        if (-not $bundle) { $bundle='unattributed' }
        if (-not $bundles.Contains($bundle)) { $bundles[$bundle]=[ordered]@{succeeded=0;failed=0} }
        $bundles[$bundle][[string]$metric.status]++
    }
    foreach ($filename in @('health-recovery-attempts.jsonl','health-targeted-resume-attempts.jsonl')) {
        foreach ($line in @(Read-Tail (Join-Path $taskDir.FullName $filename))) {
            try { $record=$line|ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $signature=[string](Field $record failureSignature '')
            $attempt=[string](Field $record executionAttemptId (Field $record attemptId ''))
            $repair=[string](Field $record ecosystemRepairStatus '')
            $type=[string](Field $record type '')
            $status=[string](Field $record targetedResumeStatus '')
            if ($type -in @('targeted-resume-completed','targeted-resume-failed')) { $status=[string](Field $record status '') }
            $restored=Field $record TaskProgressRestored $null
            if ($signature -notmatch '^[a-fA-F0-9]{64}$' -or -not $attempt -or $repair -ne 'repaired' -or ($status -notin @('completed','failed','waiting','interrupted') -and $null -eq $restored)) { $uncorrelated++; continue }
            $key=@($taskDir.Name,$signature,$attempt)|ConvertTo-Json -Compress
            $success=($status -eq 'completed' -or $restored -eq $true)
            if ($conflicted.ContainsKey($key)) { continue }
            if ($resumes.ContainsKey($key) -and $resumes[$key] -ne $success) { $conflicting++; $conflicted[$key]=$true; $resumes.Remove($key); continue }
            $resumes[$key]=$success
        }
    }
}
$healthRoot=Join-Path $stateRoot 'health'; $wait=[Collections.Generic.List[double]]::new(); $hold=[Collections.Generic.List[double]]::new(); $lockExcluded=0
foreach ($line in @(Read-Tail (Join-Path $healthRoot 'lock-metrics.jsonl'))) {
    try {
        $record=$line|ConvertFrom-Json -ErrorAction Stop
        if ((Field $record eventType) -ne 'lock-acquisition' -or $null -eq (Field $record waitMs) -or $null -eq (Field $record holdMs)) { throw 'Not a lock observation.' }
        $w=[double]$record.waitMs; $h=[double]$record.holdMs
        if ($w -lt 0 -or $h -lt 0 -or [double]::IsNaN($w) -or [double]::IsNaN($h) -or [double]::IsInfinity($w) -or [double]::IsInfinity($h)) { throw 'Invalid observation.' }
        $wait.Add($w); $hold.Add($h)
    } catch { $lockExcluded++ }
}
$scheduled=@()
foreach ($name in @('scheduled-review-poll.json','scheduled-review-daily.json','scheduled-review-manual.json','continuation-recovery-result.json','daily-incident-heartbeat.json')) {
    $item=Read-Json (Join-Path $healthRoot $name)
    if ($item) { $scheduled+=@{name=$name;status=Field $item status;checkedAtUtc=Field $item checkedAtUtc} }
}
$restoredCount=@($resumes.Values|Where-Object{$_ -eq $true}).Count
$report=[ordered]@{
    schemaVersion='1.0.0';kind='ecosystem-stability-report';generatedAtUtc=[DateTime]::UtcNow.ToString('o')
    measurement=[ordered]@{scope='bounded-recorded-evidence';maxLinesPerFile=$MaxLinesPerFile;percentile='nearest-rank';wholeHistory=$false}
    evidence=[ordered]@{failureRecords=$failureCount;roleAttemptMetricLines=$metricLines;scheduledAndHeartbeatArtifacts=$scheduled}
    activeFailures=$active;historicalStaleOrCompletedFailures=$historical
    missingIdentity=@{failureRecordsWithoutRunId=$missingRun;failureRecordsWithoutAttemptId=$missingAttempt}
    attemptCohort=@{uniqueTaskRunAttemptCount=$cohorts.Count;excludedSparseLines=$sparse;excludedMalformedLines=$malformed;excludedDuplicateLines=$duplicates;excludedNonterminalLines=$nonterminal;byBundle=$bundles}
    lockMetrics=@{sampleCount=$wait.Count;excludedCount=$lockExcluded;p50WaitMs=Percentile @($wait) .5;p95WaitMs=Percentile @($wait) .95;p50HoldMs=Percentile @($hold) .5;p95HoldMs=Percentile @($hold) .95}
    repairedAndResumed=@{count=if($resumes.Count){$restoredCount}else{$null};denominator=if($resumes.Count){$resumes.Count}else{$null};rate=if($resumes.Count){$restoredCount/$resumes.Count}else{$null};uncorrelatedRows=$uncorrelated;conflictingRows=$conflicting}
    slo=@{taskCompletionRate=$null;taskCompletionRateReason='Task completion is not an SLO.'}
}
if ($OutputPath) { Write-Utf8NoBomAtomic -Path $OutputPath -Content (($report|ConvertTo-Json -Depth 12)+[Environment]::NewLine) }
[pscustomobject]@{Report=[pscustomobject]$report;OutputPath=$OutputPath}
