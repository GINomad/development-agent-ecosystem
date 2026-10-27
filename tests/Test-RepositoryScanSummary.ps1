[CmdletBinding()]
param([string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\repository-scan-summary'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$path = Join-Path $fixtureRoot 'transcript.jsonl'
$utf8 = [Text.UTF8Encoding]::new($false)
$knowledge = @(
    [pscustomobject]@{ attemptId='attempt-one'; agentId='developer'; sourceKind='repository-map'; accessMode='reused'; status='succeeded' },
    [pscustomobject]@{ attemptId='attempt-two'; agentId='reviewer'; sourceKind='repository-map'; accessMode='rebuilt'; status='succeeded' },
    [pscustomobject]@{ agentId='legacy'; sourceKind='repository-map'; accessMode='reused'; status='succeeded' },
    [pscustomobject]@{ attemptId='failed-attempt'; agentId='developer'; sourceKind='repository-map'; accessMode='reused'; status='failed' }
)
function Write-Records([object[]] $Records) {
    [IO.File]::WriteAllText($path, ((@($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)
}
function Get-Summary {
    & (Join-Path $root 'scripts/Get-RepositoryScanSummary.ps1') -Path $path -KnowledgeRecords $knowledge -RepositoryRoots @('C:/repo')
}
function Command-Record([string] $Id, [string] $Command, [string] $Type='item.completed') {
    @{ type=$Type; item=@{ type='command_execution'; id=$Id; command=$Command } }
}
$checks = 0
foreach ($command in @(
    'rg --files', 'rg --files .', 'rg --files ./', 'rg --files ./*',
    "rg --files -g '!node_modules/**'", 'rg --files --sort path', 'rg --files . server',
    "rg --files -g '*.cs' -g '*'", 'rg --files -Tcs',
    'git ls-files', 'git -C C:/repo ls-files --cached --others --exclude-standard',
    'Get-ChildItem -LiteralPath C:/repo -Recurse -File', 'gci -Recurse', 'dir /s', 'find . -type f',
    "pwsh -NoProfile -Command 'rg --files'", '"C:/runtime/pwsh.exe" -Command "rg --files"',
    "rg --files; rg --files server -g '*.cs'"
)) {
    Write-Records @(@{type='ecosystem-workflow-run';attemptId='attempt-one'}, (Command-Record 'scan' $command 'item.started'), (Command-Record 'scan' $command), (Command-Record 'scan' $command))
    $summary = Get-Summary
    if ($summary.FullScanCount -ne 1 -or $summary.TargetedSearchCount -ne 0) { throw "Broad enumeration was missed or double-counted: $command ($($summary | ConvertTo-Json -Compress -Depth 5))" }
    $checks++
}
foreach ($command in @(
    "rg --files -g 'AGENTS.md'", "rg --files -g'*.cs'", 'rg --files --glob=*.cs',
    "rg --files -g '!node_modules/**' -g '*.cs'", 'rg --files server/src',
    "rg --files | rg 'Migrations|Snapshot' | Select-Object -First 80",
    "git ls-files -- '*.cs'", 'git ls-files server', 'git -C C:/repo ls-files server',
    'Get-ChildItem -Path server -Recurse -File', 'gci -Recurse -Filter AGENTS.md',
    "find . -name '*.cs'", 'dir server /s', 'findstr /s SomeSymbol *.cs',
    '"C:/runtime/pwsh.exe" -Command "rg --files server | rg Migrations"'
)) {
    Write-Records @(@{type='ecosystem-workflow-run';attemptId='attempt-one'}, (Command-Record 'search' $command))
    $summary = Get-Summary
    if ($summary.FullScanCount -ne 0 -or $summary.TargetedSearchCount -ne 1) { throw "Targeted file discovery was counted as a full scan: $command ($($summary | ConvertTo-Json -Compress -Depth 5))" }
    $checks++
}
Write-Records @(
    (Command-Record 'old-unbound' 'rg --files'),
    @{type='ecosystem-workflow-run';attemptId='old-attempt'}, (Command-Record 'old' 'rg --files'),
    @{type='ecosystem-workflow-run';attemptId='failed-attempt'}, (Command-Record 'failed' 'rg --files'),
    @{type='ecosystem-workflow-run';attemptId='attempt-one'},
    @{type='thread.started';thread_id='thread-one'}, (Command-Record 'same-id' 'rg --files'),
    (Command-Record 'same-id' 'rg --files'), (Command-Record 'started-only' 'rg --files' 'item.started'),
    @{type='thread.started';thread_id='thread-two'}, (Command-Record 'same-id' 'rg --files'),
    @{type='ecosystem-workflow-run';attemptId='attempt-two'},
    @{type='thread.started';thread_id='thread-one'}, (Command-Record 'same-id' 'rg --files'),
    (Command-Record 'dynamic' 'rg --files $scope'),
    (Command-Record 'quoted' "Write-Output 'rg --files'"),
    (Command-Record 'comment' '# rg --files'),
    (Command-Record 'function' 'function List-Files { rg --files }'),
    (Command-Record 'content' 'rg -n SomeSymbol server')
)
$summary = Get-Summary
if ($summary.FullScanCount -ne 3 -or $summary.ExcludedCommandCount -ne 3 -or $summary.UnclassifiedCommandCount -ne 1 -or $summary.MapEventCount -ne 2 -or $summary.ExcludedMapEventCount -ne 1 -or $summary.CoveredAttemptCount -ne 2) { throw "Attempt coverage, item identity, failed telemetry, or non-command text handling regressed: $($summary | ConvertTo-Json -Depth 5)" }
if ([string]$summary.Events[0].agentId -ne 'developer' -or [string]$summary.Events[2].agentId -ne 'reviewer') { throw 'Scan attribution was not taken from matching attempt telemetry.' }
$checks++
$empty = & (Join-Path $root 'scripts/Get-RepositoryScanSummary.ps1') -Path $path -KnowledgeRecords @()
if ($empty.FullScanCount -ne 0 -or $empty.MapEventCount -ne 0 -or $empty.CoveredAttemptCount -ne 0) { throw 'History without knowledge telemetry entered scan avoidance.' }
$checks++
[pscustomobject]@{Status='passed';Checks=$checks;OutputRoot=$fixtureRoot}
