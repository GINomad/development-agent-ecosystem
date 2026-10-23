[CmdletBinding()]
param([string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/dashboard-concurrency'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/AgentEcosystem.psm1') -Force
$fixture = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
$scripts = Join-Path $fixture 'scripts'
$state = Join-Path $fixture 'state'
New-Item -ItemType Directory -Path $scripts,(Join-Path $state 'tasks/concurrency-task') -Force | Out-Null
foreach ($name in @('Start-AgentDashboard.ps1','Get-AgentActivity.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root "scripts/$name") -Destination (Join-Path $scripts $name)
}
# Keep real configuration validation and activity reading, substituting only a
# deterministic slow analytics worker in an isolated copy of the HTTP host.
$module = Get-Content -LiteralPath (Join-Path $root 'scripts/AgentEcosystem.psm1') -Raw
$module = [regex]::Replace($module, '(?s)function Get-EcosystemRoot \{.*?\r?\n\}', ('function Get-EcosystemRoot { return ''' + $root.Replace("'", "''") + "' }"), 1)
Write-Utf8NoBom -Path (Join-Path $scripts 'AgentEcosystem.psm1') -Content $module
Write-Utf8NoBom -Path (Join-Path $scripts 'Get-DashboardInsights.ps1') -Content @'
param([string]$ProjectId, [string]$ConfigPath, [string]$CodexHome)
$settings = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
[IO.File]::WriteAllText((Join-Path $settings.runtime.stateRoot ('started-' + $ProjectId)), 'started')
Start-Sleep -Seconds 4
if ($ProjectId -eq 'lss') { throw 'Synthetic analytics failure' }
[pscustomobject]@{ projectId=$ProjectId; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); workerId=[guid]::NewGuid().ToString('N'); analytics=@{summary=@{taskCount=1;totalTokens=123}} }
'@
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try { $portProbe.Start(); $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port } finally { $portProbe.Stop() }
$settings = Get-Content -LiteralPath (Join-Path $root 'config/agents.json') -Raw | ConvertFrom-Json
$settings.runtime.stateRoot = $state
$settings.ui.port = $port
$configPath = Join-Path $fixture 'agents.json'
Write-Utf8NoBom -Path $configPath -Content ($settings | ConvertTo-Json -Depth 100)
Write-Utf8NoBom -Path (Join-Path $state 'tasks/concurrency-task/task.json') -Content (@{taskId='concurrency-task';currentStage='developer';agentStatuses=@{developer=@{status='running';message='Synthetic live entry';updatedAtUtc=[DateTime]::UtcNow.ToString('o')}}} | ConvertTo-Json -Depth 6)
$stdout = Join-Path $fixture 'server.out.log'
$stderr = Join-Path $fixture 'server.err.log'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-File',(Join-Path $scripts 'Start-AgentDashboard.ps1'),'-NoOpen','-ConfigPath',$configPath) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(30)
$baseUrl = "http://127.0.0.1:$port"
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $sessionToken = $null
    do {
        if (Test-Path -LiteralPath $stdout) {
            $line = Get-Content -LiteralPath $stdout -First 1
            if ($line -match '\?token=(\S+)$') { $sessionToken = $Matches[1] }
        }
        if (-not $sessionToken) { Start-Sleep -Milliseconds 100 }
    } while (-not $sessionToken -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if (-not $sessionToken) { throw ('Fixture server did not start: ' + (Get-Content $stderr -Raw)) }
    $client.DefaultRequestHeaders.Add('X-Ecosystem-Token',$sessionToken)
    $first = $client.GetAsync("$baseUrl/api/insights?projectId=planning-space")
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path (Join-Path $state 'started-planning-space'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Analytics worker did not start.' }
        Start-Sleep -Milliseconds 50
    }
    $second = $client.GetAsync("$baseUrl/api/insights?projectId=planning-space")
    $cancelSource = [Threading.CancellationTokenSource]::new()
    $cancelled = $client.GetAsync("$baseUrl/api/insights?projectId=planning-space", $cancelSource.Token)
    Start-Sleep -Milliseconds 100
    $cancelSource.Cancel()
    try { $null = $cancelled.GetAwaiter().GetResult(); throw 'Cancelled caller unexpectedly completed.' }
    catch [OperationCanceledException] { }
    finally { $cancelSource.Dispose() }
    $failed = $client.GetAsync("$baseUrl/api/insights?projectId=lss")
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $live = $client.GetAsync("$baseUrl/api/tasks/concurrency-task/agents/developer/log").GetAwaiter().GetResult()
    $liveBody = $live.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    $health = $client.GetAsync("$baseUrl/health").GetAwaiter().GetResult()
    $elapsed = $timer.Elapsed.TotalSeconds
    if ([int]$live.StatusCode -ne 200 -or @($liveBody.entries).Count -eq 0 -or [int]$health.StatusCode -ne 200) { throw 'Live activity or health failed while analytics was running.' }
    if ($first.IsCompleted -or $elapsed -gt 3) { throw "Analytics blocked live activity: $elapsed seconds." }
    $bodies = @()
    foreach ($pending in @($first,$second)) {
        $response = $pending.GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) { throw 'Concurrent analytics request failed.' }
        $bodies += ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
        $response.Dispose()
    }
    if ($bodies[0].workerId -ne $bodies[1].workerId -or $bodies[0].projectId -ne 'planning-space') { throw 'Same-project requests were not coalesced or lost their project binding.' }
    $failedResponse = $failed.GetAwaiter().GetResult()
    if ([int]$failedResponse.StatusCode -ne 500) { throw 'Analytics worker failure was not returned as an API error.' }
    $failedResponse.Dispose()
    $afterFailure = $client.GetAsync("$baseUrl/api/tasks/concurrency-task/agents/developer/log").GetAwaiter().GetResult()
    if ([int]$afterFailure.StatusCode -ne 200) { throw 'Analytics failure broke live activity.' }
    $afterFailure.Dispose()
    $live.Dispose(); $health.Dispose()
    [pscustomobject]@{Passed=$true;LiveAndHealthSeconds=[Math]::Round($elapsed,3);SlowAnalyticsSeconds=4;Coalesced=$true;CancellationIsolation=$true;FailureIsolation=$true;OutputRoot=$fixture}
}
finally {
    $client.Dispose()
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
