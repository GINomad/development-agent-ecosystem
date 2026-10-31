[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path ([IO.Path]::GetTempPath()) ('st-' + [guid]::NewGuid().ToString('N').Substring(0,8)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$checks = [Collections.Generic.List[string]]::new()
$classifier = Join-Path $root 'scripts\Get-ProviderFailureClassification.ps1'
foreach ($positive in @('Provider rate limit reached.','quota limit reached','Individual spend limit reached.','You have hit your usage limit.','Selected model is at capacity.','{"type":"error","error":{"code":"insufficient_quota","message":"Request rejected"}}')) {
    if (-not (& $classifier -Diagnostic $positive).IsProviderLimit) { throw "Missed genuine limit: $positive" }
}
foreach ($negative in @('capacityFallback.enabled is true. Local validator failed.','configured capacity is 2','quota metrics were loaded','Execution retry limit reached after 3 identical failures: invalid argument','{"taskId":"t","agentStatuses":{},"message":"Provider rate limit reached."}','{"type":"item.completed","item":{"status":"completed","aggregated_output":"Provider rate limit reached."}}','{"settings":{"capacity":"Selected model is at capacity"}}')) {
    if ((& $classifier -Diagnostic $negative).IsProviderLimit) { throw "False provider limit: $negative" }
}
if ((& $classifier -Diagnostic 'Failed to authenticate: OAuth session expired and could not be refreshed').Category -ne 'provider-authentication') { throw 'Expected external authentication was not separated.' }
$resolved = & (Join-Path $root 'scripts\Resolve-ProviderExecutionFailure.ps1') -ExitCode 1 -Provider codex -LogPath fixture -FailureDetail 'OAuth session expired' -Reason ''
if (-not $resolved.IsExternal -or $resolved.IsProviderLimit -or $resolved.Message -ne 'OAuth session expired') { throw 'Authentication category was lost at runner boundary.' }
$checks.Add('structured provider errors; genuine limits; negative config/tool cases; expected authentication')

$config = Get-EcosystemConfig -ConfigPath $ConfigPath
$config.runtime.stateRoot = Join-Path $OutputRoot 'state'
$config.review.monitorDataRoot = Join-Path $OutputRoot 'review'
$testCodexHome = Join-Path $OutputRoot 'home'
$null = New-Item -ItemType Directory -Path (Join-Path $testCodexHome 'agents') -Force
$sentinel = Join-Path $testCodexHome 'agents\sentinel.toml'
Write-Utf8NoBom -Path $sentinel -Content 'user-owned-profile'
$aPath = Join-Path $OutputRoot 'a.json'; $bPath = Join-Path $OutputRoot 'b.json'
Write-Utf8NoBom -Path $aPath -Content ($config | ConvertTo-Json -Depth 80)
$config.agents[0].description += ' Alternate isolated configuration.'
Write-Utf8NoBom -Path $bPath -Content ($config | ConvertTo-Json -Depth 80)
$bundleScript = Join-Path $root 'scripts\New-AgentLaunchBundle.ps1'
$taskA = Join-Path $OutputRoot 'task-a'; $taskB = Join-Path $OutputRoot 'task-b'
$a = & $bundleScript -TaskRoot $taskA -RunId 'run-aaaaaaaaaaaa' -ConfigPath $aPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile
$b = & $bundleScript -TaskRoot $taskB -RunId 'run-bbbbbbbbbbbb' -ConfigPath $bPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile
if ($a.Fingerprint -eq $b.Fingerprint -or @($a.AgentFiles).Count -ne 16 -or @($a.Overrides).Count -ne 16) { throw 'Separate config bundles collided or missed roles.' }
$before = Get-EcosystemFileSha256 -Path $a.ManifestPath
$reused = & $bundleScript -TaskRoot $taskA -RunId 'run-aaaaaaaaaaaa' -ConfigPath $aPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile
if (-not $reused.Reused -or (Get-EcosystemFileSha256 -Path $a.ManifestPath) -ne $before -or [IO.File]::ReadAllText($sentinel) -ne 'user-owned-profile') { throw 'Bundle reuse rewrote immutable evidence or global profile.' }
try { & $bundleScript -TaskRoot $taskA -RunId 'run-aaaaaaaaaaaa' -ConfigPath $bPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile | Out-Null; throw 'Changed bundle inputs accepted.' }
catch { if ($_.Exception.Message -eq 'Changed bundle inputs accepted.') { throw } }
Write-Utf8NoBom -Path $b.AgentFiles[0] -Content 'tampered'
try { & $bundleScript -TaskRoot $taskB -RunId 'run-bbbbbbbbbbbb' -ConfigPath $bPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile | Out-Null; throw 'Tampered bundle accepted.' }
catch { if ($_.Exception.Message -eq 'Tampered bundle accepted.') { throw } }
$manifest = Get-Content -LiteralPath $a.ManifestPath -Raw | ConvertFrom-Json
$outside = Join-Path $OutputRoot 'outside.toml'
Write-Utf8NoBom -Path $outside -Content 'untrusted'
$manifest.agentFiles[0].path = $outside
$manifest.agentFiles[0].sha256 = Get-EcosystemFileSha256 -Path $outside
Write-Utf8NoBom -Path $a.ManifestPath -Content ($manifest|ConvertTo-Json -Depth 15)
try { & $bundleScript -TaskRoot $taskA -RunId 'run-aaaaaaaaaaaa' -ConfigPath $aPath -CodexHome $testCodexHome -IncludeHostCompatibilityProfile | Out-Null; throw 'Escaped manifest accepted.' }
catch { if ($_.Exception.Message -eq 'Escaped manifest accepted.') { throw } }
$checks.Add('cross-config isolation; immutable reuse; content and manifest/path tampering; no global install')

$fixture = Join-Path $OutputRoot 'transport-fixture.ps1'
$fixtureSource = @'
param([string]$Mode,[string]$Log)
if ($Mode -eq 'burst') {
    1..3 | ForEach-Object { [Console]::Error.WriteLine('stream connection failed; waiting to retry error=Connection failed: error sending request'); [Console]::Error.Flush() }
    Start-Sleep -Seconds 20
} elseif ($Mode -eq 'stall') {
    [Console]::Error.WriteLine('stream connection failed; waiting to retry'); [Console]::Error.Flush()
    Start-Sleep -Seconds 20
} elseif ($Mode -eq 'recovered') {
    [Console]::Error.WriteLine('stream connection failed; waiting to retry'); [Console]::Error.Flush()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $Log) -or -not ([IO.File]::ReadAllText($Log).Contains('ecosystem-transport-retry'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Transport observation barrier timed out.' }
        Start-Sleep -Milliseconds 20
    }
    [Console]::Out.WriteLine('{"type":"item.started","item":{"type":"command_execution","status":"in_progress"}}'); [Console]::Out.Flush()
    Start-Sleep -Seconds 2
    [Console]::Out.WriteLine('{"type":"turn.completed"}'); [Console]::Out.Flush()
} elseif ($Mode -eq 'product') {
    [Console]::Error.WriteLine('TypeScript compiler warning; capacityFallback=true is config.'); [Console]::Error.Flush()
    Start-Sleep -Seconds 2
    [Console]::Out.WriteLine('{"type":"turn.completed"}'); [Console]::Out.Flush()
} elseif ($Mode -eq 'auth') {
    [Console]::Out.WriteLine('{"type":"error","message":"Failed to authenticate: OAuth session expired"}'); [Console]::Out.Flush()
    Start-Sleep -Seconds 20
}
'@
Write-Utf8NoBom -Path $fixture -Content $fixtureSource
$runner = Join-Path $root 'scripts\Invoke-GuardedCodex.ps1'
foreach ($mode in @('burst','stall','recovered','product','auth')) {
    $log = Join-Path $OutputRoot ($mode + '.jsonl')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $result = & $runner -FilePath powershell.exe -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Mode',$mode,'-Log',$log) -Prompt '' -WorkingDirectory $root -LogPath $log -GuardArtifactPath (Join-Path $OutputRoot ($mode + '-guard.json')) -MaxTransportFailures 3 -TransportNoProgressSeconds 1 -PollMilliseconds 100 -MaxRunMinutes 1
    $watch.Stop()
    if ($mode -in @('burst','stall')) {
        if (-not $result.guardTriggered -or $result.failureKind -ne 'provider-transport' -or $watch.Elapsed.TotalSeconds -gt 12) { throw "Transport watchdog failed: $mode" }
    } elseif ($mode -eq 'auth') {
        if (-not $result.guardTriggered -or $result.failureCanonical -notmatch 'OAuth session expired') { throw 'Structured auth event was not terminal.' }
    } else {
        if ($result.guardTriggered -or $result.exitCode -ne 0) { throw "Recovered/long product work incorrectly timed out: $mode" }
    }
}
$checks.Add('real child processes: repeated transport, no-progress stall, recovery barrier, long product work, typed auth')

$metricsPath = Join-Path $OutputRoot 'lock-metrics.jsonl'
$lockPath = Join-Path $OutputRoot 'lock'
$output = Invoke-EcosystemFileLock -LockPath $lockPath -MetricsPath $metricsPath -CorrelationId 'task/run/attempt' -Action { 'real-result' }
$metric = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
if ($output -ne 'real-result' -or $metric.status -ne 'completed' -or $metric.waitMs -lt 0 -or $metric.holdMs -lt 0) { throw 'Lock metrics changed the action result or lost observations.' }
try { Invoke-EcosystemFileLock -LockPath $lockPath -MetricsPath $metricsPath -Action { throw 'original action failure' }; throw 'Lost expected failure.' }
catch { if ($_.Exception.Message -ne 'original action failure') { throw } }
$metricHeld = [IO.File]::Open(($metricsPath+'.metrics.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { $actual = Invoke-EcosystemFileLock -LockPath $lockPath -MetricsPath $metricsPath -Action { 'metrics-cannot-block-work' } }
finally { $metricHeld.Dispose() }
if ($actual -ne 'metrics-cannot-block-work') { throw 'Diagnostic contention changed work.' }
$checks.Add('lock diagnostics retain output/original exception and cannot block work')

$cancelFixture = Join-Path $OutputRoot 'cancel-child.ps1'
$identityPath = Join-Path $OutputRoot 'child-identity.txt'
Write-Utf8NoBom -Path $cancelFixture -Content ('param([string]$IdentityPath)' + "`n" + '[IO.File]::WriteAllText($IdentityPath,[string]$PID); Start-Sleep -Seconds 30')
$cancelLog = Join-Path $OutputRoot 'cancel.jsonl'
try {
    & $runner -FilePath powershell.exe -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$cancelFixture,'-IdentityPath',$identityPath) -Prompt '' -WorkingDirectory $root -LogPath $cancelLog -GuardArtifactPath (Join-Path $OutputRoot 'cancel-guard.json') -HeartbeatIntervalSeconds 5 -HeartbeatAction { throw 'synthetic heartbeat failure' } -PollMilliseconds 100 -MaxRunMinutes 1 | Out-Null
    throw 'Heartbeat failure was swallowed.'
} catch { if ($_.Exception.Message -ne 'synthetic heartbeat failure') { throw } }
$childId = [int][IO.File]::ReadAllText($identityPath)
if (Get-Process -Id $childId -ErrorAction SilentlyContinue) { throw 'Cancelled runner left a live child process.' }
if (@(Get-ChildItem -LiteralPath $OutputRoot -Filter 'cancel.jsonl.*' | Where-Object { $_.Name -match 'stdin.txt$|stdout.tmp$' }).Count) { throw 'Cancelled runner left prompt/stdout temporary files.' }
$checks.Add('heartbeat exception terminates child, releases process resources and removes temporary prompt/output')
[pscustomobject]@{ Passed=$true; Checks=@($checks); OutputRoot=$OutputRoot }
