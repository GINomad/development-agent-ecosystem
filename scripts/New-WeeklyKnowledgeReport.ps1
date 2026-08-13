[CmdletBinding()]
param(
    [DateTime] $AsOf = (Get-Date),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.knowledge.weeklyReport
if (-not [bool]$policy.enabled) { return [pscustomobject]@{ Status='disabled' } }

$taskHistoryRoot = Resolve-EcosystemPath -Value ([string]$config.knowledge.taskHistoryRoot) -Config $config -CodexHome $CodexHome
$outputRoot = Resolve-EcosystemPath -Value ([string]$policy.outputRoot) -Config $config -CodexHome $CodexHome
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$periodEndUtc = $AsOf.ToUniversalTime()
$periodStartUtc = $periodEndUtc.AddDays(-[int]$policy.lookbackDays)
$learning = [Collections.Generic.List[object]]::new()
$decisions = [Collections.Generic.List[object]]::new()
$completedTasks = [Collections.Generic.List[object]]::new()
$sources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Test-InReportPeriod {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [ref]$parsed)) { return $false }
    $utc = $parsed.UtcDateTime
    $utc -ge $periodStartUtc -and $utc -le $periodEndUtc
}

if (Test-Path -LiteralPath $taskHistoryRoot -PathType Container) {
    foreach ($taskDirectory in @(Get-ChildItem -LiteralPath $taskHistoryRoot -Directory | Sort-Object Name)) {
        $knowledgePath = Join-Path $taskDirectory.FullName 'knowledge-update.json'
        if (Test-Path -LiteralPath $knowledgePath -PathType Leaf) {
            try { $knowledge = Get-Content -LiteralPath $knowledgePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $knowledge = $null }
            if ($knowledge) {
                foreach ($entry in @($knowledge.entries)) {
                    if ([string]$entry.status -notin @('verified','superseded') -or -not (Test-InReportPeriod -Value ([string]$entry.observedAtUtc))) { continue }
                    $learning.Add([pscustomobject][ordered]@{
                        taskId = if ($knowledge.PSObject.Properties['taskId']) { [string]$knowledge.taskId } else { $taskDirectory.Name }
                        id = [string]$entry.id
                        status = [string]$entry.status
                        statement = [string]$entry.statement
                        source = [string]$entry.source
                        revision = [string]$entry.revision
                        observedAtUtc = [string]$entry.observedAtUtc
                        observedBy = [string]$entry.observedBy
                        targetPath = [string]$entry.targetPath
                    })
                }
                $null = $sources.Add($knowledgePath)
            }
        }

        $summaryPath = Join-Path $taskDirectory.FullName 'task-summary.json'
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            try { $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $summary = $null }
            if ($summary -and [string]$summary.status -eq 'completed' -and (Test-InReportPeriod -Value ([string]$summary.completedAtUtc))) {
                $taskId = if ($summary.PSObject.Properties['taskId']) { [string]$summary.taskId } else { $taskDirectory.Name }
                $completedTasks.Add([pscustomobject][ordered]@{ taskId=$taskId; completedAtUtc=[string]$summary.completedAtUtc; repositories=@($summary.repositories); knowledgeUpdates=@($summary.knowledgeUpdates) })
                foreach ($statement in @($summary.decisions)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$statement)) { $decisions.Add([pscustomobject][ordered]@{ taskId=$taskId; statement=[string]$statement; source=$summaryPath }) }
                }
                $null = $sources.Add($summaryPath)
            }
        }
    }
}

$verified = @($learning | Where-Object status -eq 'verified' | Sort-Object observedAtUtc,id)
$superseded = @($learning | Where-Object status -eq 'superseded' | Sort-Object observedAtUtc,id)
$skills = @($verified | Where-Object { [string]$_.targetPath -match '(?i)(skill|coding|style|standard|guideline|practice|prompt|principle)' })
$reportId = 'knowledge-weekly-' + $AsOf.ToString('yyyyMMdd')
$report = [pscustomobject][ordered]@{
    reportId = $reportId
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    period = [pscustomobject][ordered]@{
        startUtc = $periodStartUtc.ToString('o')
        endUtc = $periodEndUtc.ToString('o')
        timeZone = [TimeZoneInfo]::Local.Id
        schedule = "$([string]$policy.dayOfWeek) $([string]$policy.localTime) local time"
    }
    summary = [pscustomobject][ordered]@{ verifiedLearning=$verified.Count; skillsAndPractices=$skills.Count; supersededLearning=$superseded.Count; decisions=$decisions.Count; completedTasks=$completedTasks.Count }
    skillsAndPractices = @($skills)
    verifiedLearning = @($verified)
    supersededLearning = @($superseded)
    decisions = @($decisions)
    completedTasks = @($completedTasks)
    sources = @($sources | Sort-Object)
}

$jsonPath = Join-Path $outputRoot ($reportId + '.json')
$htmlPath = Join-Path $outputRoot ($reportId + '.html')
Write-Utf8NoBom -Path $jsonPath -Content (($report | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

function Encode-Html([object] $Value) { [Net.WebUtility]::HtmlEncode([string]$Value) }
function Add-LearningSection {
    param([Text.StringBuilder] $Builder, [string] $Title, [object[]] $Items, [string] $EmptyText)
    [void]$Builder.AppendLine('<section><h2>' + (Encode-Html $Title) + '</h2>')
    if (-not $Items.Count) { [void]$Builder.AppendLine('<p class="empty">' + (Encode-Html $EmptyText) + '</p></section>'); return }
    [void]$Builder.AppendLine('<div class="cards">')
    foreach ($item in $Items) {
        [void]$Builder.AppendLine('<article><h3>' + (Encode-Html $item.statement) + '</h3>')
        [void]$Builder.AppendLine('<dl><dt>Task</dt><dd>' + (Encode-Html $item.taskId) + '</dd><dt>Target</dt><dd>' + (Encode-Html $item.targetPath) + '</dd><dt>Revision</dt><dd>' + (Encode-Html $item.revision) + '</dd><dt>Observed</dt><dd>' + (Encode-Html $item.observedAtUtc) + ' by ' + (Encode-Html $item.observedBy) + '</dd><dt>Source</dt><dd>' + (Encode-Html $item.source) + '</dd></dl></article>')
    }
    [void]$Builder.AppendLine('</div></section>')
}

$html = [Text.StringBuilder]::new()
[void]$html.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Knowledge Keeper weekly learning report</title><style>body{margin:0;background:#071016;color:#e9f2f7;font:15px/1.55 Segoe UI,Arial,sans-serif}main{max-width:1400px;margin:auto;padding:32px}h1{font-size:36px;margin:0 0 8px}h2{margin-top:32px;color:#83f3cb}.meta,.empty{color:#a9bdc9}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:24px 0}.stat,article{background:#101b24;border:1px solid #29404f;border-radius:12px;padding:16px}.stat strong{display:block;font-size:28px;color:#83f3cb}.cards{display:grid;gap:12px}article h3{margin:0 0 12px;font-size:17px}dl{display:grid;grid-template-columns:100px 1fr;gap:4px 12px;margin:0}dt{color:#8ca5b4}dd{margin:0;overflow-wrap:anywhere}ul{padding-left:22px}code{color:#ffd37a}</style></head><body><main>')
[void]$html.AppendLine('<h1>Knowledge Keeper weekly learning report</h1><p class="meta">Generated ' + (Encode-Html $AsOf.ToString('yyyy-MM-dd HH:mm:ss zzz')) + ' · ' + (Encode-Html $report.period.schedule) + ' · period ' + (Encode-Html $report.period.startUtc) + ' — ' + (Encode-Html $report.period.endUtc) + '</p>')
[void]$html.AppendLine('<div class="stats"><div class="stat"><strong>'+$skills.Count+'</strong>skills &amp; practices</div><div class="stat"><strong>'+$verified.Count+'</strong>verified learning entries</div><div class="stat"><strong>'+$decisions.Count+'</strong>decisions</div><div class="stat"><strong>'+$completedTasks.Count+'</strong>completed tasks</div></div>')
Add-LearningSection -Builder $html -Title 'Skills, style, and engineering practices learned' -Items $skills -EmptyText 'No verified skill or engineering-practice changes were published during this period.'
Add-LearningSection -Builder $html -Title 'All verified knowledge learned' -Items $verified -EmptyText 'No verified knowledge updates were published during this period.'
Add-LearningSection -Builder $html -Title 'Superseded knowledge' -Items $superseded -EmptyText 'No durable knowledge was superseded during this period.'
[void]$html.AppendLine('<section><h2>Development and process decisions</h2>')
if (-not $decisions.Count) { [void]$html.AppendLine('<p class="empty">No completed-task decisions were published during this period.</p>') } else { [void]$html.AppendLine('<ul>'); foreach($decision in $decisions){ [void]$html.AppendLine('<li><strong>'+(Encode-Html $decision.taskId)+':</strong> '+(Encode-Html $decision.statement)+'</li>') }; [void]$html.AppendLine('</ul>') }
[void]$html.AppendLine('</section><section><h2>Evidence sources</h2><ul>')
foreach($source in @($report.sources)){ [void]$html.AppendLine('<li><code>'+(Encode-Html $source)+'</code></li>') }
[void]$html.AppendLine('</ul></section></main></body></html>')
Write-Utf8NoBom -Path $htmlPath -Content $html.ToString()
Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $outputRoot 'latest.json') -Force
Copy-Item -LiteralPath $htmlPath -Destination (Join-Path $outputRoot 'latest.html') -Force

[pscustomobject]@{ Status='generated'; ReportId=$reportId; HtmlPath=$htmlPath; JsonPath=$jsonPath; VerifiedLearning=$verified.Count; SkillsAndPractices=$skills.Count; Decisions=$decisions.Count; CompletedTasks=$completedTasks.Count }
