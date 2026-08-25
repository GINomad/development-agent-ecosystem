[CmdletBinding()]
param(
    [string] $SourceId = 'ps-excel-agent-initial',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$sourceConfig = @($config.knowledge.seedSources | Where-Object { $_.id -eq $SourceId }) | Select-Object -First 1
if (-not $sourceConfig) { throw "Knowledge seed '$SourceId' is not configured." }
$sourceRoot = Resolve-EcosystemPath -Value ([string]$sourceConfig.path) -Config $config -CodexHome $CodexHome
$managedRoot = Resolve-EcosystemPath -Value ([string]$config.knowledge.managedRoot) -Config $config -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Knowledge seed root was not found: $sourceRoot" }
if ([string]::Equals($sourceRoot.TrimEnd('\'), $managedRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Seed and managed knowledge roots must be different.'
}
New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null

$manifestPath = Join-Path $managedRoot '.knowledge-import.json'
$previous = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }
$previousByPath = @{}
if ($previous) {
    foreach ($entry in @($previous.entries)) { $previousByPath[[string]$entry.relativePath] = $entry }
}
$extensions = @($sourceConfig.includeExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
$sourceUri = [Uri]($sourceRoot.TrimEnd('\') + '\')
$entries = [Collections.Generic.List[object]]::new()
$conflicts = [Collections.Generic.List[string]]::new()

foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | Sort-Object FullName)) {
    if ($file.FullName -match '[\\/]\.git[\\/]') { continue }
    if ($file.Extension.ToLowerInvariant() -notin $extensions) { continue }
    $relative = [Uri]::UnescapeDataString($sourceUri.MakeRelativeUri([Uri]$file.FullName).ToString()).Replace('/', '\')
    $target = Join-Path $managedRoot $relative
    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $status = 'copied'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        $prior = $previousByPath[$relative]
        if ($targetHash -eq $sourceHash) {
            $status = 'unchanged'
        }
        elseif ($prior -and ($targetHash -ne [string]$prior.importedHash -or [string]$prior.status -eq 'skipped-managed-change')) {
            $status = 'skipped-managed-change'
            $conflicts.Add($relative)
        }
    }
    if ($status -eq 'copied') {
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $importedHash = if (Test-Path -LiteralPath $target) { (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    $entries.Add([pscustomobject][ordered]@{
        relativePath = $relative
        sourcePath = $file.FullName
        sourceHash = $sourceHash
        importedHash = $importedHash
        sourceLastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
        status = $status
    })
}

$manifest = [pscustomobject][ordered]@{
    sourceId = $SourceId
    sourceRoot = $sourceRoot
    managedRoot = $managedRoot
    importedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    entries = @($entries)
    conflicts = @($conflicts)
}
$manifestUpdated = $true
if ($previous) {
    $previousImportTime = [string]$previous.importedAtUtc
    $previous.importedAtUtc = [string]$manifest.importedAtUtc
    $previousComparable = $previous | ConvertTo-Json -Depth 8 -Compress
    $currentComparable = $manifest | ConvertTo-Json -Depth 8 -Compress
    if ([string]::Equals($previousComparable, $currentComparable, [StringComparison]::Ordinal)) {
        $manifestUpdated = $false
        $manifest.importedAtUtc = $previousImportTime
    }
}
if ($manifestUpdated) {
    $temporary = "$manifestPath.tmp"
    Write-Utf8NoBom -Path $temporary -Content (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Move-Item -LiteralPath $temporary -Destination $manifestPath -Force
}
[pscustomobject]@{
    SourceRoot = $sourceRoot
    ManagedRoot = $managedRoot
    ManifestPath = $manifestPath
    FileCount = $entries.Count
    ConflictCount = $conflicts.Count
    Conflicts = @($conflicts)
    ManifestUpdated = $manifestUpdated
}
