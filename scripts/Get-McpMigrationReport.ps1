[CmdletBinding()]
param(
    [string] $MetricsRoot,
    [ValidateSet('classic','mcp','mcp-with-tool-fallback','classic-after-mcp-failure')][string] $BaselineMode = 'classic',
    [ValidateSet('mcp','mcp-with-tool-fallback')][string] $CanaryMode = 'mcp',
    [int] $MinimumSampleSize = 30,
    [double] $MinimumSuccessRate = 0.98,
    [double] $MinimumFallbackSuccessRate = 0.99,
    [double] $MaximumErrorRate = 0.02,
    [double] $MaximumP95LatencyRatio = 1.10,
    [double] $MaximumQualityRegression = 0.05,
    [switch] $IncludeSynthetic,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if(-not(Get-Command Get-EcosystemStateRoot -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Global}
$config = Get-EcosystemConfig
$usingDefaultMetricsRoot = [string]::IsNullOrWhiteSpace($MetricsRoot)
if ($usingDefaultMetricsRoot) { $MetricsRoot = Join-Path (Get-EcosystemStateRoot -Config $config) 'tasks' }
if (-not (Test-Path -LiteralPath $MetricsRoot -PathType Container)) { throw "Metrics root was not found: $MetricsRoot" }
$resolvedMetricsRoot = [IO.Path]::GetFullPath($MetricsRoot)

function Read-LockedJsonLines {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $line | ConvertFrom-Json } catch { Write-Warning "Ignoring invalid JSONL metric in $Path." }
            }
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
function Get-Percentile {
    param([double[]] $Values, [double] $Percentile)
    if (-not $Values.Count) { return $null }
    $ordered = @($Values | Sort-Object)
    $index = [Math]::Min($ordered.Count - 1, [Math]::Ceiling($Percentile * $ordered.Count) - 1)
    [Math]::Round($ordered[$index], 2)
}
function Get-Mode {
    param($Record)
    if ($Record.PSObject.Properties['effectiveMode'] -and -not [string]::IsNullOrWhiteSpace([string]$Record.effectiveMode)) { return [string]$Record.effectiveMode }
    if ($Record.PSObject.Properties['mode'] -and [string]$Record.mode -eq 'mcp' -and -not $Record.PSObject.Properties['mcpCallCount']) { return 'mcp-unverified' }
    foreach ($name in @('contextAccessMode','mode','mcpMode')) {
        if ($Record.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$Record.$name)) { return [string]$Record.$name }
    }
    if ($Record.PSObject.Properties['mcpEnabled']) { return $(if ([bool]$Record.mcpEnabled) { 'mcp' } else { 'classic' }) }
    'unknown'
}

$records = [Collections.Generic.List[object]]::new()
$includedFiles = [Collections.Generic.List[string]]::new()
$excludedFiles = [Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $resolvedMetricsRoot -Recurse -File -Filter 'role-metrics.jsonl' -ErrorAction SilentlyContinue)) {
    $relativePath = [IO.Path]::GetRelativePath($resolvedMetricsRoot, $file.FullName)
    $segments = @($relativePath -split '[\\/]')
    $reason = $null
    if ($segments -contains 'revisions') { $reason = 'archived-revision' }
    elseif (-not $IncludeSynthetic -and $segments[0] -like 'mcp-smoke-*') { $reason = 'synthetic-task' }
    elseif ($usingDefaultMetricsRoot -and ($segments.Count -ne 2 -or $segments[0] -notlike 'task-*')) { $reason = 'non-production-layout' }
    if ($reason) { $excludedFiles.Add([pscustomobject]@{path=$file.FullName;reason=$reason}); continue }
    $includedFiles.Add($file.FullName)
    foreach ($record in @(Read-LockedJsonLines -Path $file.FullName)) {
        if ($record.PSObject.Properties['metricLevel'] -and [string]$record.metricLevel -ne 'role') { continue }
        if ($record.PSObject.Properties['eventType'] -and [string]$record.eventType -ne 'role-attempt-completed') { continue }
        $records.Add([pscustomobject]@{File=$file.FullName;Record=$record;Mode=(Get-Mode $record)})
    }
}

function Get-Summary {
    param([object[]] $Items)
    $count = @($Items).Count
    $success = @($Items | Where-Object { [string]$_.Record.status -in @('succeeded','completed','success') }).Count
    $fallbacks = @($Items | Where-Object { ($_.Record.PSObject.Properties['fallbackUsed'] -and [bool]$_.Record.fallbackUsed) -or [string]$_.Mode -in @('mcp-with-tool-fallback','classic-after-mcp-failure') })
    $fallbackSuccess = @($fallbacks | Where-Object { [string]$_.Record.status -in @('succeeded','completed','success') }).Count
    $latencies = @($Items | ForEach-Object { if ($_.Record.PSObject.Properties['durationMs'] -and $null -ne $_.Record.durationMs) { [double]$_.Record.durationMs } })
    $comparableQuality = @($Items | Where-Object { $_.Record.PSObject.Properties['qualityComparable'] -and [bool]$_.Record.qualityComparable -and $_.Record.PSObject.Properties['qualityObserved'] -and [bool]$_.Record.qualityObserved })
    $quality = @($comparableQuality | ForEach-Object { foreach ($key in @('qualityValue','qualityProxy','evidenceCoverage','findingPrecisionProxy')) { if ($_.Record.PSObject.Properties[$key] -and $null -ne $_.Record.$key) { [double]$_.Record.$key; break } } })
    [pscustomobject]@{
        sampleSize = $count
        successRate = $(if($count){[Math]::Round($success/$count,4)}else{$null})
        errorRate = $(if($count){[Math]::Round(($count-$success)/$count,4)}else{$null})
        fallbackCount = $fallbacks.Count
        fallbackSuccessRate = $(if($fallbacks.Count){[Math]::Round($fallbackSuccess/$fallbacks.Count,4)}else{$null})
        p50LatencyMs = Get-Percentile $latencies .50
        p95LatencyMs = Get-Percentile $latencies .95
        qualityObservedCount = $comparableQuality.Count
        qualityProxy = $(if($quality.Count -eq $count -and $quality.Count){[Math]::Round((($quality|Measure-Object -Average).Average),4)}else{$null})
    }
}
function New-Gate([string]$Name,[string]$Status,[AllowNull()][object]$Observed,[AllowNull()][object]$Threshold,[string]$Reason) {
    [pscustomobject]@{name=$Name;status=$Status;observed=$Observed;threshold=$Threshold;reason=$Reason}
}

$baseline = Get-Summary @($records | Where-Object Mode -eq $BaselineMode)
$canary = Get-Summary @($records | Where-Object Mode -eq $CanaryMode)
$fallback = Get-Summary @($records | Where-Object { ($_.Record.PSObject.Properties['fallbackUsed'] -and [bool]$_.Record.fallbackUsed) -or [string]$_.Mode -in @('mcp-with-tool-fallback','classic-after-mcp-failure') })
$latencyRatio = if ($baseline.p95LatencyMs -and $canary.p95LatencyMs) { [Math]::Round($canary.p95LatencyMs/$baseline.p95LatencyMs,4) } else { $null }
$qualityDelta = if ($null -ne $baseline.qualityProxy -and $null -ne $canary.qualityProxy) { [Math]::Round($canary.qualityProxy-$baseline.qualityProxy,4) } else { $null }
$samplePassed = $baseline.sampleSize -ge $MinimumSampleSize -and $canary.sampleSize -ge $MinimumSampleSize
$gates = [Collections.Generic.List[object]]::new()
$gates.Add((New-Gate 'sampleSize' $(if($samplePassed){'passed'}else{'failed'}) "baseline=$($baseline.sampleSize);canary=$($canary.sampleSize)" $MinimumSampleSize 'Both modes require the configured number of role attempts.'))
$gates.Add((New-Gate 'successRate' $(if($null -eq $canary.successRate){'missing'}elseif($canary.successRate -ge $MinimumSuccessRate){'passed'}else{'failed'}) $canary.successRate $MinimumSuccessRate 'Canary successful role-attempt rate.'))
$gates.Add((New-Gate 'errorRate' $(if($null -eq $canary.errorRate){'missing'}elseif($canary.errorRate -le $MaximumErrorRate){'passed'}else{'failed'}) $canary.errorRate $MaximumErrorRate 'Canary failed role-attempt rate.'))
$gates.Add((New-Gate 'fallbackSuccessRate' $(if(-not $fallback.sampleSize){'not-applicable'}elseif($fallback.successRate -ge $MinimumFallbackSuccessRate){'passed'}else{'failed'}) $fallback.successRate $MinimumFallbackSuccessRate 'Fallback attempts are evaluated across the complete role-attempt set.'))
$gates.Add((New-Gate 'p95LatencyRatio' $(if($null -eq $latencyRatio){'missing'}elseif($latencyRatio -le $MaximumP95LatencyRatio){'passed'}else{'failed'}) $latencyRatio $MaximumP95LatencyRatio 'Canary P95 divided by baseline P95.'))
$gates.Add((New-Gate 'qualityRegression' $(if($null -eq $qualityDelta){'missing'}elseif($qualityDelta -ge -$MaximumQualityRegression){'passed'}else{'failed'}) $qualityDelta (-$MaximumQualityRegression) 'Only explicitly comparable independent quality evidence is accepted.'))
$hardFailures = @($gates | Where-Object { $_.name -ne 'sampleSize' -and $_.status -eq 'failed' })
$missingGates = @($gates | Where-Object status -eq 'missing')
$decision = if(-not $samplePassed){'hold'}elseif($hardFailures.Count){'rollback'}elseif($missingGates.Count){'hold'}else{'continue'}
$reasons = @($gates | Where-Object { $_.status -notin @('passed','not-applicable') } | ForEach-Object { "$($_.name): $($_.status) ($($_.reason))" })
if(-not $reasons.Count){$reasons=@('sample size and every applicable migration gate passed')}
$byRoleServer = @($records | Group-Object { "$([string]$_.Record.agentId)|$([string]$_.Record.server)|$($_.Mode)" } | ForEach-Object { $parts=$_.Name -split '\|',3; [pscustomobject]@{agentId=$parts[0];server=$parts[1];mode=$parts[2];summary=(Get-Summary $_.Group)} })
$report = [ordered]@{
    schemaVersion=2;generatedAtUtc=[DateTime]::UtcNow.ToString('o');metricsRoot=$resolvedMetricsRoot;baselineMode=$BaselineMode;canaryMode=$CanaryMode
    measurementContext=[ordered]@{recordCount=$records.Count;includedFiles=@($includedFiles);excludedFiles=@($excludedFiles);modes=@($records|ForEach-Object{$_.Mode}|Select-Object -Unique);servers=@($records|ForEach-Object{[string]$_.Record.server}|Where-Object{$_}|Select-Object -Unique);roles=@($records|ForEach-Object{[string]$_.Record.agentId}|Where-Object{$_}|Select-Object -Unique)}
    thresholds=[ordered]@{minimumSampleSize=$MinimumSampleSize;minimumSuccessRate=$MinimumSuccessRate;minimumFallbackSuccessRate=$MinimumFallbackSuccessRate;maximumErrorRate=$MaximumErrorRate;maximumP95LatencyRatio=$MaximumP95LatencyRatio;maximumQualityRegression=$MaximumQualityRegression}
    baseline=$baseline;canary=$canary;fallback=$fallback;p95LatencyRatio=$latencyRatio;qualityProxyDelta=$qualityDelta;gates=@($gates);decision=$decision;reasons=@($reasons);byRoleServer=$byRoleServer
}
if (-not $OutputPath) { $OutputPath = Join-Path $MetricsRoot 'mcp-migration-report.json' }
Write-Utf8NoBomAtomic -Path $OutputPath -Content (($report|ConvertTo-Json -Depth 20)+[Environment]::NewLine)
[pscustomobject]@{ReportPath=[IO.Path]::GetFullPath($OutputPath);Report=[pscustomobject]$report}
