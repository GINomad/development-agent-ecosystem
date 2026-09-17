[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputRoot,
    [ValidateRange(1,365)][int] $RetentionDays = 14,
    [string] $CurrentRunPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resolvedRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\','/')
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { return @() }
$resolvedCurrent = if ($CurrentRunPath) { [IO.Path]::GetFullPath($CurrentRunPath).TrimEnd('\','/') } else { $null }
$cutoff = [DateTime]::UtcNow.AddDays(-$RetentionDays)
$removed = [Collections.Generic.List[string]]::new()
foreach ($directory in @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Force)) {
    $candidate = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\','/')
    if (-not $candidate.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to inspect test output outside '$resolvedRoot'." }
    if ($resolvedCurrent -and $candidate.Equals($resolvedCurrent, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $marker = Join-Path $candidate '.ecosystem-test-output.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or $directory.LastWriteTimeUtc -ge $cutoff) { continue }
    Remove-Item -LiteralPath $candidate -Recurse -Force
    $removed.Add($candidate)
}
return @($removed)
