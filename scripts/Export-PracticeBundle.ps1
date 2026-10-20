[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\development-agent-ecosystem\practice-bundle.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne '1.0' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or -not @($manifest.assets).Count) { throw 'Invalid practice bundle manifest.' }
$files = @(); $seen = @{}
foreach ($asset in @($manifest.assets)) {
    $relative = [string]$asset.path
    if ($relative -notmatch '^plugins/development-agent-ecosystem/skills/analyze-requirements/[A-Za-z0-9_./-]+$' -or
        @($relative.Split('/') | Where-Object { $_ -in @('.','..','') }).Count -or $seen.ContainsKey($relative)) { throw 'Invalid or duplicate bundle asset path.' }
    $seen[$relative] = $true
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Bundle asset escaped repository.' }
    $current = $path
    while ($current -and $current -ne $root) {
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bundle assets cannot traverse reparse points.' }
        $current = Split-Path -Parent $current
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$asset.sha256) { throw "Practice asset digest mismatch: $relative" }
    $files += [pscustomobject]@{path=$path;relative=$relative;sha256=[string]$asset.sha256}
}
$destination = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($destination) -ne '.zip' -or (Test-Path -LiteralPath $destination)) { throw 'Choose a new .zip destination.' }
$parent = Split-Path -Parent $destination
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$staging = Join-Path $parent ('practice-bundle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $staging 'practice-bundle.json')
    foreach ($file in $files) {
        $target = Join-Path $staging $file.relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.path -Destination $target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) { throw 'Bundle staging digest mismatch.' }
    }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $destination -ErrorAction Stop
    [pscustomobject]@{version=$manifest.version;path=$destination;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant();assetCount=$files.Count}
}
finally {
    # Only the exact GUID staging directory created above is removed.
    if ([IO.Path]::GetFullPath($staging).StartsWith($parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($staging) -match '^practice-bundle-[a-f0-9]{32}$') { Remove-Item -LiteralPath $staging -Recurse -Force }
}
