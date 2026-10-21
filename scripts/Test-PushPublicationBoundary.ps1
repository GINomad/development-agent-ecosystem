[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($line in ([Console]::In.ReadToEnd() -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -ne 4 -or $parts[1] -notmatch '^[a-f0-9]{40}$') { throw 'Invalid Git pre-push ref input.' }
    if ($parts[1] -eq ('0' * 40)) { continue }
    & (Join-Path $PSScriptRoot 'Test-PublicationBoundary.ps1') -Revision $parts[1] -History | Out-Null
}
