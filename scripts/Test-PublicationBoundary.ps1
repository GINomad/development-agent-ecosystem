[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot), [string] $Revision, [switch] $History)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$paths = @(if ($History) {
    if (-not $Revision) { throw 'History inspection requires an explicit revision.' }
    $historyObjects = @(& git -C $Root rev-list --objects $Revision)
    $fingerprintPath = Join-Path $Root 'knowledge/local/private-history-fingerprints.local.json'
    if (Test-Path -LiteralPath $fingerprintPath -PathType Leaf) {
        $blockedHashes = @{}
        foreach ($item in @(Get-Content -LiteralPath $fingerprintPath -Raw | ConvertFrom-Json)) { $blockedHashes[[string]$item.sha] = $true }
        $matches = @($historyObjects | Where-Object { $blockedHashes.ContainsKey(($_ -split ' ',2)[0]) })
        if ($matches.Count) { throw 'Publication history contains a known private blob.' }
    }
    $historyObjects | ForEach-Object { if ($_ -match '^[a-f0-9]{40} (.+)$') { $Matches[1] } }
} elseif ($Revision) { & git -C $Root ls-tree -r --name-only $Revision } else { & git -C $Root ls-files })
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect publication tree.' }
$privatePaths = @($paths | Where-Object { $_ -match '^(knowledge/(managed/projects|local)/|artifacts/)' -or $_ -match '\.local\.json$' -or $_ -eq 'implementation-plan.json' -or $_ -eq 'plugins/development-agent-ecosystem/skills/azure-pipeline-monitor/references/planning-space.md' })
if ($privatePaths.Count) { throw "Publication tree contains $($privatePaths.Count) private project/runtime paths. Remove them from the index while preserving local files." }
[pscustomobject]@{Passed=$true; TrackedFiles=$paths.Count; PrivateFiles=0; Scope=if ($Revision) {$Revision} else {'index'}}
