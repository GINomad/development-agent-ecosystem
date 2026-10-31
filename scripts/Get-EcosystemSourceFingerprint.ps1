[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$paths = @(& git -C $Root -c core.quotePath=false ls-files -z --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate source provenance.' }
$relativePaths = @((($paths -join "`n").Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) | Sort-Object -Unique)
$records = [Collections.Generic.List[string]]::new()
foreach ($relative in $relativePaths) {
    $path = Join-Path $Root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $records.Add($relative.Replace('\','/') + ':' + $hash)
    }
}
$sha = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($records -join "`n"))))).Replace('-','').ToLowerInvariant() }
finally { $sha.Dispose() }
$revision = ([string](& git -C $Root rev-parse HEAD)).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve source revision.' }
$dirty = @(& git -C $Root status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve source worktree state.' }
[pscustomobject]@{ Fingerprint=$fingerprint; Revision=$revision; Dirty=($dirty.Count -gt 0); FileCount=$records.Count }
