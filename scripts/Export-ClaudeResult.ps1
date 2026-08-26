[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LogPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [switch] $Structured
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { throw "Claude output log was not found: $LogPath" }

$events = [Collections.Generic.List[object]]::new()
foreach ($line in @(Get-Content -LiteralPath $LogPath -Encoding UTF8)) {
    try { $events.Add(($line | ConvertFrom-Json)) } catch { }
}
$resultEvent = @($events | Where-Object { [string]$_.type -eq 'result' }) | Select-Object -Last 1
if (-not $resultEvent) {
    try { $resultEvent = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if (-not $resultEvent) { throw 'Claude did not emit a parseable result event.' }

if ($Structured) {
    $value = if ($resultEvent.PSObject.Properties['structured_output']) { $resultEvent.structured_output } elseif ($resultEvent.PSObject.Properties['result']) { [string]$resultEvent.result | ConvertFrom-Json } else { throw 'Claude result did not contain structured_output.' }
    $content = ($value | ConvertTo-Json -Depth 30) + [Environment]::NewLine
}
else {
    if (-not $resultEvent.PSObject.Properties['result']) { throw 'Claude result did not contain final text.' }
    $content = [string]$resultEvent.result
    if (-not $content.EndsWith([Environment]::NewLine)) { $content += [Environment]::NewLine }
}
Write-Utf8NoBom -Path $OutputPath -Content $content
[pscustomobject]@{ LogPath=[IO.Path]::GetFullPath($LogPath); OutputPath=[IO.Path]::GetFullPath($OutputPath); Structured=[bool]$Structured }
