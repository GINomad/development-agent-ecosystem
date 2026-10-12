[CmdletBinding()]
param([string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\dashboard-insights'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
$fixtureRoot = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $fixtureRoot 'state'
$taskRoot = Join-Path $stateRoot 'tasks\insight-task'
New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
$portListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try { $portListener.Start(); $dashboardPort = ([Net.IPEndPoint]$portListener.LocalEndpoint).Port }
finally { $portListener.Stop() }
$config = Get-Content -LiteralPath (Join-Path $root 'config\agents.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.runtime.stateRoot = $stateRoot
$config.ui.listenAddress = '127.0.0.1'
$config.ui.port = $dashboardPort
$config.ui.openBrowser = $false
$configPath = Join-Path $fixtureRoot 'agents.json'
Write-Utf8NoBom -Path $configPath -Content (($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine)

$task = [ordered]@{ taskId='insight-task'; projectId='planning-space'; selector='Synthetic dashboard insight task'; status='completed'; updatedAtUtc='2026-10-12T12:00:00Z' }
Write-Utf8NoBom -Path (Join-Path $taskRoot 'task.json') -Content (($task | ConvertTo-Json) + [Environment]::NewLine)
$tokens = @(
    [ordered]@{ taskId='insight-task'; agentId='developer'; provider='codex'; model='gpt-test'; availability='reported'; inputTokens=100; outputTokens=50; cacheReadTokens=20; cacheWriteTokens=0; totalTokens=150 },
    [ordered]@{ taskId='insight-task'; agentId='reviewer'; provider='copilot'; model='copilot-test'; availability='unavailable'; inputTokens=$null; outputTokens=$null; cacheReadTokens=$null; cacheWriteTokens=$null; totalTokens=$null }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'token-usage.jsonl') -Content ((@($tokens | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$metrics = @(
    [ordered]@{ eventType='role-attempt-completed'; agentId='developer'; status='failed' },
    [ordered]@{ eventType='role-attempt-completed'; agentId='reviewer'; status='succeeded' }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'role-metrics.jsonl') -Content ((@($metrics | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$archivedRevisionRoot = Join-Path $taskRoot 'revisions\revision-1'
New-Item -ItemType Directory -Path $archivedRevisionRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $taskRoot 'token-usage.jsonl') -Destination (Join-Path $archivedRevisionRoot 'token-usage.jsonl')
Copy-Item -LiteralPath (Join-Path $taskRoot 'role-metrics.jsonl') -Destination (Join-Path $archivedRevisionRoot 'role-metrics.jsonl')
$failure = [ordered]@{ eventId='failure-1'; type='agent-failure'; actor='developer'; timestampUtc='2026-10-12T11:30:00Z'; summary='Synthetic developer failure.' }
Write-Utf8NoBom -Path (Join-Path $taskRoot 'task-ledger.jsonl') -Content (($failure | ConvertTo-Json -Compress) + [Environment]::NewLine)
$knowledge = [ordered]@{
    taskId='insight-task'
    entries=@([ordered]@{ id='KN-1'; status='verified'; statement='Synthetic verified project knowledge.'; source='synthetic'; revision='git:abc'; observedAtUtc='2026-10-12T11:45:00Z'; observedBy='knowledge_keeper'; targetPath='knowledge/synthetic.md'; kind='fact'; scope='planning-space'; evidence=@('task-summary.json') })
    humanReadable=[ordered]@{ title='Synthetic knowledge'; overview='Synthetic overview.'; audience='Developers'; updates=@([ordered]@{ knowledgeId='KN-1'; title='Synthetic'; description='Verified outcome.'; applicability='planning-space'; status='verified' }) }
}
Write-Utf8NoBom -Path (Join-Path $taskRoot 'knowledge-update.json') -Content (($knowledge | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
$summary = [ordered]@{ outcomes=@([ordered]@{ agentId='knowledge_keeper'; summary='Knowledge Keeper published one verified fact.' }); humanReadable=[ordered]@{ knowledgeUpdates=@() } }
Write-Utf8NoBom -Path (Join-Path $taskRoot 'task-summary.json') -Content (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

$result = & (Join-Path $root 'scripts\Get-DashboardInsights.ps1') -ProjectId planning-space -ConfigPath $configPath
if ([int]$result.analytics.summary.taskCount -ne 1 -or [long]$result.analytics.summary.totalTokens -ne 150 -or [int]$result.analytics.summary.reportedTokenRecordCount -ne 1 -or [int]$result.analytics.summary.unavailableTokenRecordCount -ne 1 -or [int]$result.analytics.summary.attemptCount -ne 2) { throw 'Dashboard analytics did not aggregate cumulative task metrics exactly once.' }
if ([int]$result.analytics.summary.errorCount -ne 1 -or [int]$result.analytics.summary.failedAttemptCount -ne 1 -or [string]$result.analytics.recentErrors[0].agentId -ne 'developer') { throw 'Dashboard analytics did not aggregate failures.' }
if ([int]$result.knowledge.outcomeCount -ne 1 -or [int]$result.knowledge.verifiedEntryCount -ne 1 -or [string]$result.knowledge.outcomes[0].entries[0].id -ne 'KN-1' -or [string]$result.knowledge.outcomes[0].keeperOutcomes[0] -notmatch 'verified fact') { throw 'Dashboard knowledge outcomes are not bound to the source task.' }
$dashboardServer = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
$dashboardHtml = Get-Content -LiteralPath (Join-Path $root 'dashboard\index.html') -Raw -Encoding UTF8
$dashboardClient = Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
if ($dashboardServer -notmatch "'/api/insights'" -or $dashboardServer -notmatch 'Get-DashboardInsights\.ps1' -or $dashboardHtml -notmatch 'id="analyticsWorkspace"' -or $dashboardHtml -notmatch 'id="knowledgeWorkspace"' -or $dashboardClient -notmatch '/api/insights' -or $dashboardClient -notmatch 'renderAnalytics' -or $dashboardClient -notmatch 'renderKnowledge') { throw 'Dashboard insights endpoint or analytics/knowledge views are not wired end to end.' }
$stdout = Join-Path $fixtureRoot 'dashboard.out.log'
$stderr = Join-Path $fixtureRoot 'dashboard.err.log'
$dashboardProcess = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',(Join-Path $root 'scripts\Start-AgentDashboard.ps1'),'-NoOpen','-MaxRequests','1','-ConfigPath',$configPath) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $sessionToken = $null
    do {
        if (Test-Path -LiteralPath $stdout -PathType Leaf) {
            $serverLine = Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($serverLine -match '\?token=(?<token>\S+)$') { $sessionToken = [string]$Matches.token }
        }
        if (-not $sessionToken) { Start-Sleep -Milliseconds 100 }
    } while (-not $sessionToken -and -not $dashboardProcess.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if (-not $sessionToken) { throw "Dashboard did not start for insights API validation. $((Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))" }
    $apiResult = Invoke-RestMethod -Uri "http://127.0.0.1:$dashboardPort/api/insights?projectId=planning-space" -Headers @{ 'X-Ecosystem-Token'=$sessionToken }
    if ([long]$apiResult.analytics.summary.totalTokens -ne 150 -or [string]$apiResult.knowledge.outcomes[0].taskId -ne 'insight-task') { throw 'Dashboard insights HTTP endpoint did not return the aggregated project data.' }
    $dashboardProcess.WaitForExit(5000) | Out-Null
}
finally {
    if (-not $dashboardProcess.HasExited) { Stop-Process -Id $dashboardProcess.Id -Force -ErrorAction SilentlyContinue }
}

[pscustomobject]@{ Status='passed'; Checks=5; OutputRoot=$fixtureRoot }
