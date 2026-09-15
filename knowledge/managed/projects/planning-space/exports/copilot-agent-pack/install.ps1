[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetRoot,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$sourceRoot = Join-Path $PSScriptRoot 'repository'
$resolvedSourceRoot = (Resolve-Path -LiteralPath $sourceRoot).Path

if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
    throw "Target repository does not exist: $TargetRoot"
}

$resolvedTargetRoot = (Resolve-Path -LiteralPath $TargetRoot).Path
$sourceFiles = Get-ChildItem -LiteralPath $resolvedSourceRoot -Recurse -File

foreach ($sourceFile in $sourceFiles) {
    $relativePath = $sourceFile.FullName.Substring($resolvedSourceRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $resolvedTargetRoot $relativePath

    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        throw "Refusing to overwrite '$destination'. Review it first or rerun with -Force."
    }

    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($destination, "Install $relativePath")) {
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination -Force:$Force
    }
}

Write-Host "Installed $($sourceFiles.Count) Copilot customization files into $resolvedTargetRoot"
Write-Host 'Open VS Code and run: Chat: Open Customizations'
