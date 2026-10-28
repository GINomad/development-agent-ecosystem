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
    [ordered]@{ timestampUtc='2026-10-11T22:00:00Z'; taskId='insight-task'; agentId='developer'; provider='codex'; model='gpt-test'; availability='reported'; inputTokens=40; outputTokens=10; cacheReadTokens=20; cacheWriteTokens=0; totalTokens=50 },
    [ordered]@{ timestampUtc='2026-10-12T23:30:00+00:00'; taskId='insight-task'; agentId='developer'; provider='codex'; model='gpt-test'; availability='partial'; inputTokens=60; outputTokens=40; cacheReadTokens=0; cacheWriteTokens=0; totalTokens=100 },
    [ordered]@{ timestampUtc='2026-10-12T23:45:00Z'; taskId='insight-task'; agentId='reviewer'; provider='copilot'; model='copilot-test'; availability='unavailable'; inputTokens=$null; outputTokens=$null; cacheReadTokens=$null; cacheWriteTokens=$null; totalTokens=$null },
    [ordered]@{ taskId='insight-task'; agentId='knowledge_keeper'; provider='legacy'; model='legacy-test' }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'token-usage.jsonl') -Content ((@($tokens | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$metrics = @(
    [ordered]@{ eventType='role-attempt-completed'; agentId='developer'; status='failed' },
    [ordered]@{ eventType='role-attempt-completed'; agentId='reviewer'; status='succeeded' },
    [ordered]@{ agentId='knowledge_keeper'; status='succeeded'; durationMs=25 }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'role-metrics.jsonl') -Content ((@($metrics | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$mcpMetrics = @(
    [ordered]@{ schemaVersion=2; metricLevel='tool'; eventType='mcp-tool-call-completed'; timestampUtc='2026-10-12T11:10:00Z'; taskId='insight-task'; agentId='developer'; server='ecosystem-read'; tool='get_repository_map'; status='succeeded'; durationMs=40; requestBytes=120; responseBytes=800; fallbackUsed=$false },
    [ordered]@{ schemaVersion=2; metricLevel='tool'; eventType='mcp-tool-call-completed'; timestampUtc='2026-10-12T11:11:00Z'; taskId='insight-task'; agentId='developer'; server='ecosystem-read'; tool='get_repository_map'; status='failed'; durationMs=900; requestBytes=120; responseBytes=0; fallbackUsed=$true },
    [ordered]@{ schemaVersion=2; metricLevel='transport'; eventType='mcp-transport-failed'; timestampUtc='2026-10-12T11:12:00Z'; taskId='insight-task'; agentId='developer'; server='ecosystem-read'; tool=''; status='failed'; durationMs=0; requestBytes=0; responseBytes=0; fallbackUsed=$true; errorClass='transport-or-protocol' }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'mcp-metrics.jsonl') -Content ((@($mcpMetrics | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$knowledgeUsage = @(
    [ordered]@{ schemaVersion=1; metricLevel='knowledge'; eventType='knowledge-access'; eventId='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; timestampUtc='2026-10-12T11:05:00Z'; taskId='insight-task'; agentId='developer'; sourceKind='skill'; accessMode='selected'; sourceId='develop-dotnet'; cacheHit=$false; evidenceKind='observed'; status='succeeded' },
    [ordered]@{ schemaVersion=1; metricLevel='knowledge'; eventType='knowledge-access'; eventId='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; timestampUtc='2026-10-12T11:06:00Z'; taskId='insight-task'; agentId='developer'; attemptId='covered-attempt'; sourceKind='repository-map'; accessMode='reused'; sourceId='repo-one'; repositoryId='repo-one'; cacheHit=$true; evidenceKind='observed'; status='succeeded' },
    [ordered]@{ schemaVersion=1; metricLevel='knowledge'; eventType='knowledge-access'; eventId='cccccccccccccccccccccccccccccccc'; timestampUtc='2026-10-12T11:07:00Z'; taskId='insight-task'; agentId='developer'; attemptId='covered-attempt'; sourceKind='repository-map'; accessMode='rebuilt'; sourceId='repo-two'; repositoryId='repo-two'; cacheHit=$false; evidenceKind='observed'; status='succeeded' }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'knowledge-usage.jsonl') -Content ((@($knowledgeUsage | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
[IO.File]::AppendAllText((Join-Path $taskRoot 'knowledge-usage.jsonl'), (($knowledgeUsage[1] | ConvertTo-Json -Compress) + [Environment]::NewLine))
$transcript = @(
    @{ type='ecosystem-workflow-run'; attemptId='old-attempt' },
    @{ type='item.completed'; item=@{ id='item_0'; type='command_execution'; command='rg --files' } },
    @{ type='ecosystem-workflow-run'; attemptId='covered-attempt' },
    @{ type='thread.started'; thread_id='thread-one' },
    @{ type='item.started'; item=@{ id='item_0'; type='command_execution'; command='rg --files' } },
    @{ type='item.completed'; item=@{ id='item_0'; type='command_execution'; command='rg --files' } },
    @{ type='item.completed'; item=@{ id='item_0'; type='command_execution'; command='rg --files' } },
    @{ type='item.completed'; item=@{ id='item_1'; type='command_execution'; command="rg --files -g 'AGENTS.md'" } }
)
Write-Utf8NoBom -Path (Join-Path $taskRoot 'workflow-codex.jsonl') -Content ((@($transcript | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
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
$otherTaskRoot = Join-Path $stateRoot 'tasks\other-project-task'
New-Item -ItemType Directory -Path $otherTaskRoot -Force | Out-Null
Write-Utf8NoBom -Path (Join-Path $otherTaskRoot 'task.json') -Content (([ordered]@{ taskId='other-project-task'; projectId='lss'; selector='Synthetic other project'; status='completed'; updatedAtUtc='2026-10-12T12:00:00Z' } | ConvertTo-Json) + [Environment]::NewLine)
Write-Utf8NoBom -Path (Join-Path $otherTaskRoot 'token-usage.jsonl') -Content (([ordered]@{ timestampUtc='2026-10-12T12:00:00Z'; taskId='other-project-task'; agentId='developer'; provider='codex'; model='gpt-test'; availability='reported'; inputTokens=400; outputTokens=100; totalTokens=500 } | ConvertTo-Json -Compress) + [Environment]::NewLine)

Write-Utf8NoBom -Path (Join-Path $otherTaskRoot 'workflow-codex.jsonl') -Content ((@{ type='item.completed'; item=@{ id='legacy'; type='command_execution'; command='rg --files' } } | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine)

$result = & (Join-Path $root 'scripts\Get-DashboardInsights.ps1') -ProjectId planning-space -ConfigPath $configPath
$allResult = & (Join-Path $root 'scripts\Get-DashboardInsights.ps1') -ConfigPath $configPath
$uncoveredResult = & (Join-Path $root 'scripts\Get-DashboardInsights.ps1') -ProjectId lss -ConfigPath $configPath
if ($null -ne $uncoveredResult.analytics.knowledgeUsage.scanAvoidanceRate -or [int]$uncoveredResult.analytics.knowledgeUsage.fullScanCount -ne 0 -or [int]$uncoveredResult.analytics.knowledgeUsage.scanExcludedCommandCount -ne 1) { throw 'A project without telemetry must report unavailable scan avoidance, not zero or a fabricated percentage.' }
if ([int]$result.analytics.summary.taskCount -ne 1 -or [long]$result.analytics.summary.totalTokens -ne 150 -or [int]$result.analytics.summary.reportedTokenRecordCount -ne 2 -or [int]$result.analytics.summary.unavailableTokenRecordCount -ne 2 -or [int]$result.analytics.summary.unassignedTokenTimestampRecordCount -ne 1 -or [int]$result.analytics.summary.attemptCount -ne 3) { throw 'Dashboard analytics did not aggregate cumulative and legacy task metrics exactly once.' }
if (@($result.analytics.tokensByDay).Count -ne 2 -or [string]$result.analytics.tokensByDay[0].date -ne '2026-10-11' -or [long]$result.analytics.tokensByDay[0].totalTokens -ne 50 -or [long]$result.analytics.tokensByDay[0].cacheReadTokens -ne 20 -or [string]$result.analytics.tokensByDay[1].date -ne '2026-10-12' -or [long]$result.analytics.tokensByDay[1].totalTokens -ne 100 -or [long]$result.analytics.tokensByDay[1].inputTokens -ne 60 -or [long]$result.analytics.tokensByDay[1].outputTokens -ne 40 -or [int]$result.analytics.tokensByDay[1].reportedRecordCount -ne 1 -or [int]$result.analytics.tokensByDay[1].unavailableRecordCount -ne 1) { throw 'Dashboard analytics did not aggregate reported token usage into chronological UTC-day deltas.' }
if ([int]$result.analytics.summary.errorCount -ne 1 -or [int]$result.analytics.summary.failedAttemptCount -ne 1 -or [string]$result.analytics.recentErrors[0].agentId -ne 'developer') { throw 'Dashboard analytics did not aggregate failures.' }
if ([int]$result.knowledge.outcomeCount -ne 1 -or [int]$result.knowledge.verifiedEntryCount -ne 1 -or [string]$result.knowledge.outcomes[0].entries[0].id -ne 'KN-1' -or [string]$result.knowledge.outcomes[0].keeperOutcomes[0] -notmatch 'verified fact') { throw 'Dashboard knowledge outcomes are not bound to the source task.' }
if ([int]$result.analytics.mcp.callCount -ne 2 -or [int]$result.analytics.mcp.failedCount -ne 1 -or [int]$result.analytics.mcp.transportEventCount -ne 1 -or [int]$result.analytics.mcp.transportFailureCount -ne 1 -or [int]$result.analytics.mcpByTool.Count -ne 1 -or [int]$result.analytics.knowledgeUsage.mapReusedCount -ne 1 -or [int]$result.analytics.knowledgeUsage.mapBuiltCount -ne 1 -or [double]$result.analytics.knowledgeUsage.mapReuseRate -ne 0.5) { throw 'Dashboard did not separate MCP tool calls from transport failures or aggregate knowledge reuse telemetry.' }
if ([int]$result.analytics.summary.taskCount -ne 1 -or [long]$result.analytics.summary.totalTokens -ne 150 -or [int]$allResult.analytics.summary.taskCount -ne 2 -or [long]$allResult.analytics.summary.totalTokens -ne 650) { throw 'Project-scoped analytics mixed or dropped telemetry across projects.' }
if ([int]$result.analytics.knowledgeUsage.fullScanCount -ne 1 -or [int]$result.analytics.knowledgeUsage.targetedSearchCount -ne 1 -or [int]$result.analytics.knowledgeUsage.scanExcludedCommandCount -ne 1 -or [double]$result.analytics.knowledgeUsage.scanAvoidanceRate -ne 0.6667) { throw 'Scan avoidance mixed uncovered history, targeted searches, or repeated command events into its denominator.' }
if ([int]$allResult.analytics.knowledgeUsage.fullScanCount -ne 1 -or [double]$allResult.analytics.knowledgeUsage.scanAvoidanceRate -ne 0.6667) { throw 'Uninstrumented tasks changed the all-project scan avoidance projection.' }
$dashboardServer = Get-Content -LiteralPath (Join-Path $root 'scripts\Start-AgentDashboard.ps1') -Raw -Encoding UTF8
$dashboardHtml = Get-Content -LiteralPath (Join-Path $root 'dashboard\index.html') -Raw -Encoding UTF8
$dashboardClient = Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
$dashboardStyles = Get-Content -LiteralPath (Join-Path $root 'dashboard\styles.css') -Raw -Encoding UTF8
if ($dashboardServer -notmatch "'/api/insights'" -or $dashboardServer -notmatch "'/analytics'" -or $dashboardServer -notmatch 'Get-DashboardInsights\.ps1' -or $dashboardHtml -notmatch 'id="analyticsWorkspace"' -or $dashboardHtml -notmatch 'id="knowledgeWorkspace"' -or $dashboardHtml -notmatch 'id="dailyTokenChart"' -or $dashboardClient -notmatch '/api/insights' -or $dashboardClient -notmatch 'renderAnalytics' -or $dashboardClient -notmatch 'renderDailyTokenChart' -or $dashboardClient -notmatch 'tokensByDay' -or $dashboardClient -notmatch 'renderKnowledge') { throw 'Dashboard insights endpoint or analytics/knowledge views are not wired end to end.' }
$analyticsHtml = Get-Content -LiteralPath (Join-Path $root 'dashboard\analytics.html') -Raw -Encoding UTF8
$analyticsClient = Get-Content -LiteralPath (Join-Path $root 'dashboard\analytics.js') -Raw -Encoding UTF8
if ($analyticsHtml -notmatch 'id="project"' -or $analyticsHtml -notmatch 'id="mcpSummary"' -or $analyticsHtml -notmatch 'id="knowledgeBySource"' -or $analyticsClient -notmatch '/api/insights' -or $analyticsClient -notmatch 'projectId' -or $analyticsClient -notmatch 'knowledgeUsage' -or $analyticsClient -notmatch 'mcpByTool' -or $analyticsClient -notmatch 'AbortController') { throw 'Standalone project-scoped analytics page is incomplete.' }
$dashboardApp = Get-Content -LiteralPath (Join-Path $root 'dashboard\app.js') -Raw -Encoding UTF8
if ($dashboardApp -notmatch 'insightsReloadPending' -or $dashboardApp -notmatch 'void loadInsights\(\{ silent: true \}\)') { throw 'Main dashboard project filter does not queue a selection made during an in-flight insights request.' }
if ($dashboardStyles -notmatch '\.insights-workspace\.hidden\s*\{\s*display:\s*none;\s*\}') { throw 'Dashboard insights tab panels can override the shared hidden utility and remain visible together.' }
if ($dashboardStyles -notmatch '\.token-chart-plot' -or $dashboardStyles -notmatch '\.token-chart-bar') { throw 'Dashboard daily token chart is missing its responsive visual contract.' }
$stdout = Join-Path $fixtureRoot 'dashboard.out.log'
$stderr = Join-Path $fixtureRoot 'dashboard.err.log'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1).Source
$dashboardProcess = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile','-File',(Join-Path $root 'scripts\Start-AgentDashboard.ps1'),'-NoOpen','-MaxRequests','3','-ConfigPath',$configPath) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
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
    if ([int]$apiResult.analytics.knowledgeUsage.fullScanCount -ne 1 -or [double]$apiResult.analytics.knowledgeUsage.scanAvoidanceRate -ne 0.6667 -or [long]$apiResult.analytics.summary.totalTokens -ne 150 -or @($apiResult.analytics.tokensByDay).Count -ne 2 -or [long]$apiResult.analytics.tokensByDay[1].totalTokens -ne 100 -or [string]$apiResult.knowledge.outcomes[0].taskId -ne 'insight-task') { throw 'Dashboard insights HTTP endpoint did not return the aggregated project data.' }
    $analyticsPage = Invoke-WebRequest -Uri "http://127.0.0.1:$dashboardPort/analytics" -UseBasicParsing
    if ($analyticsPage.StatusCode -ne 200 -or $analyticsPage.Content -notmatch 'id="project"' -or $analyticsPage.Content -match '__SESSION_TOKEN__') { throw 'Standalone analytics page was not served with a session-bound project selector.' }
    $dashboardProcess.WaitForExit(5000) | Out-Null
}
finally {
    if (-not $dashboardProcess.HasExited) { Stop-Process -Id $dashboardProcess.Id -Force -ErrorAction SilentlyContinue }
}

[pscustomobject]@{ Status='passed'; Checks=8; OutputRoot=$fixtureRoot }
