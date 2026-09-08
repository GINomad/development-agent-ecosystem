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
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if(-not(Get-Command Get-EcosystemStateRoot -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Global}
$config = Get-EcosystemConfig
if (-not $MetricsRoot) { $MetricsRoot = Join-Path (Get-EcosystemStateRoot -Config $config) 'tasks' }
if (-not (Test-Path -LiteralPath $MetricsRoot -PathType Container)) { throw "Metrics root was not found: $MetricsRoot" }

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
function Get-Percentile { param([double[]] $Values, [double] $Percentile)
    if (-not $Values.Count) { return $null }
    $ordered = @($Values | Sort-Object); $index = [Math]::Min($ordered.Count - 1, [Math]::Ceiling($Percentile * $ordered.Count) - 1)
    return [Math]::Round($ordered[$index], 2)
}
function Get-Mode { param($Record)
    foreach ($name in @('contextAccessMode','mode','mcpMode')) { if ($Record.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$Record.$name)) { return [string]$Record.$name } }
    if ($Record.PSObject.Properties['mcpEnabled']) { return $(if ([bool]$Record.mcpEnabled) { 'mcp' } else { 'classic' }) }
    return 'unknown'
}

$records = [Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath $MetricsRoot -Recurse -File -Filter '*metrics.jsonl' -ErrorAction SilentlyContinue)) {
    foreach ($record in @(Read-LockedJsonLines -Path $file.FullName)) {
        $records.Add([pscustomobject]@{ File=$file.FullName; Record=$record; Mode=(Get-Mode $record) })
    }
}
function Get-Summary { param([object[]] $Items)
    $count = @($Items).Count
    $success = @($Items | Where-Object { [string]$_.Record.status -in @('succeeded','completed','success') }).Count
    $fallbacks = @($Items | Where-Object { ($_.Record.PSObject.Properties['fallbackUsed'] -and [bool]$_.Record.fallbackUsed) -or [string]$_.Mode -in @('mcp-with-tool-fallback','classic-after-mcp-failure') })
    $fallbackSuccess = @($fallbacks | Where-Object { [string]$_.Record.status -in @('succeeded','completed','success') }).Count
    $latencies = @($Items | ForEach-Object { if ($_.Record.PSObject.Properties['durationMs'] -and $null -ne $_.Record.durationMs) { [double]$_.Record.durationMs } })
    $quality = @($Items | ForEach-Object { if(-not $_.Record.PSObject.Properties['qualityObserved'] -or -not [bool]$_.Record.qualityObserved){return}; foreach ($key in @('qualityValue','qualityProxy','evidenceCoverage','findingPrecisionProxy','artifactValidationRate')) { if ($_.Record.PSObject.Properties[$key] -and $null -ne $_.Record.$key) { [double]$_.Record.$key; break } } })
    $qualityObserved=@($Items|Where-Object{$_.Record.PSObject.Properties['qualityObserved'] -and [bool]$_.Record.qualityObserved}).Count
    [pscustomobject]@{ sampleSize=$count; successRate=$(if($count){[Math]::Round($success/$count,4)}); errorRate=$(if($count){[Math]::Round(($count-$success)/$count,4)}); fallbackCount=$fallbacks.Count; fallbackSuccessRate=$(if($fallbacks.Count){[Math]::Round($fallbackSuccess/$fallbacks.Count,4)}else{$null}); p50LatencyMs=(Get-Percentile $latencies .50); p95LatencyMs=(Get-Percentile $latencies .95); qualityObservedCount=$qualityObserved; qualityProxy=$(if($quality.Count -eq $count -and $quality.Count){[Math]::Round((($quality | Measure-Object -Average).Average),4)}else{$null}) }
}
$baseline = Get-Summary @($records | Where-Object Mode -eq $BaselineMode)
$canary = Get-Summary @($records | Where-Object Mode -eq $CanaryMode)
$latencyRatio = if ($baseline.p95LatencyMs -and $canary.p95LatencyMs) { [Math]::Round($canary.p95LatencyMs / $baseline.p95LatencyMs, 4) } else { $null }
$qualityDelta = if ($null -ne $baseline.qualityProxy -and $null -ne $canary.qualityProxy) { [Math]::Round($canary.qualityProxy - $baseline.qualityProxy,4) } else { $null }
$decision = 'hold'; $reasons = [Collections.Generic.List[string]]::new()
if ($baseline.sampleSize -lt $MinimumSampleSize -or $canary.sampleSize -lt $MinimumSampleSize) { $reasons.Add("sample-size guard: baseline=$($baseline.sampleSize), canary=$($canary.sampleSize), required=$MinimumSampleSize") }
elseif ($null -eq $baseline.qualityProxy -or $null -eq $canary.qualityProxy) { $decision='hold'; $reasons.Add('quality proxy is missing; migration cannot continue without comparable quality evidence') }
elseif ($canary.errorRate -gt $MaximumErrorRate -or $canary.successRate -lt $MinimumSuccessRate -or ($null -ne $canary.fallbackSuccessRate -and $canary.fallbackSuccessRate -lt $MinimumFallbackSuccessRate) -or ($null -ne $latencyRatio -and $latencyRatio -gt $MaximumP95LatencyRatio) -or ($null -ne $qualityDelta -and $qualityDelta -lt -$MaximumQualityRegression)) { $decision='rollback'; $reasons.Add('one or more safety, reliability, latency, or quality gates failed') }
else { $decision='continue'; $reasons.Add('sample size and all configured gates passed') }
$byRoleServer = @($records | Group-Object { "$([string]$_.Record.agentId)|$([string]$_.Record.server)|$($_.Mode)" } | ForEach-Object { $parts=$_.Name -split '\|',3; [pscustomobject]@{agentId=$parts[0];server=$parts[1];mode=$parts[2];summary=(Get-Summary $_.Group)} })
$report = [ordered]@{ schemaVersion=1; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); metricsRoot=[IO.Path]::GetFullPath($MetricsRoot); baselineMode=$BaselineMode; canaryMode=$CanaryMode; measurementContext=[ordered]@{recordCount=$records.Count;modes=@($records|ForEach-Object{$_.Mode}|Select-Object -Unique);servers=@($records|ForEach-Object{[string]$_.Record.server}|Where-Object{$_}|Select-Object -Unique);roles=@($records|ForEach-Object{[string]$_.Record.agentId}|Where-Object{$_}|Select-Object -Unique)}; thresholds=[ordered]@{minimumSampleSize=$MinimumSampleSize;minimumSuccessRate=$MinimumSuccessRate;minimumFallbackSuccessRate=$MinimumFallbackSuccessRate;maximumErrorRate=$MaximumErrorRate;maximumP95LatencyRatio=$MaximumP95LatencyRatio;maximumQualityRegression=$MaximumQualityRegression}; baseline=$baseline; canary=$canary; p95LatencyRatio=$latencyRatio; qualityProxyDelta=$qualityDelta; decision=$decision; reasons=@($reasons); byRoleServer=$byRoleServer }
if (-not $OutputPath) { $OutputPath = Join-Path $MetricsRoot 'mcp-migration-report.json' }
Write-Utf8NoBomAtomic -Path $OutputPath -Content (($report | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
[pscustomobject]@{ ReportPath=[IO.Path]::GetFullPath($OutputPath); Report=[pscustomobject]$report }
