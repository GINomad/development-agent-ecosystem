[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Repository', 'Personal', 'All')]
    [string]$Scope = 'All',

    [string]$TargetRoot,

    [string]$UserProfileRoot = $env:USERPROFILE,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'repository')).Path

function Copy-CopilotTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $resolvedSource = (Resolve-Path -LiteralPath $Source).Path
    $sourceFiles = Get-ChildItem -LiteralPath $resolvedSource -Recurse -File

    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
        $destinationFile = Join-Path $Destination $relativePath

        if ((Test-Path -LiteralPath $destinationFile) -and -not $Force) {
            throw "Refusing to overwrite '$destinationFile'. Review it first or rerun with -Force."
        }

        $destinationDirectory = Split-Path -Parent $destinationFile
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($destinationFile, "Install $relativePath")) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force:$Force
        }
    }

    return $sourceFiles.Count
}

$installedCount = 0

if ($Scope -in @('Repository', 'All')) {
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        throw 'TargetRoot is required for Repository and All scopes.'
    }

    if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) {
        throw "Target repository does not exist: $TargetRoot"
    }

    $resolvedTargetRoot = (Resolve-Path -LiteralPath $TargetRoot).Path
    $installedCount += Copy-CopilotTree -Source $sourceRoot -Destination $resolvedTargetRoot
    Write-Host "Installed repository customizations into $resolvedTargetRoot"
}

if ($Scope -in @('Personal', 'All')) {
    if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) {
        throw 'UserProfileRoot is required for Personal and All scopes.'
    }

    if (-not (Test-Path -LiteralPath $UserProfileRoot -PathType Container)) {
        throw "User profile does not exist: $UserProfileRoot"
    }

    $resolvedUserProfile = (Resolve-Path -LiteralPath $UserProfileRoot).Path
    $skillSource = Join-Path $sourceRoot '.github\skills'
    $agentSource = Join-Path $sourceRoot '.github\agents'

    $installedCount += Copy-CopilotTree -Source $skillSource -Destination (Join-Path $resolvedUserProfile '.copilot\skills')
    $installedCount += Copy-CopilotTree -Source $agentSource -Destination (Join-Path $resolvedUserProfile '.copilot\agents')
    $installedCount += Copy-CopilotTree -Source $agentSource -Destination (Join-Path $resolvedUserProfile '.github\agents')

    Write-Host "Installed personal skills for both IDEs into $resolvedUserProfile\.copilot\skills"
    Write-Host "Installed VS Code agents into $resolvedUserProfile\.copilot\agents"
    Write-Host "Installed Visual Studio agents into $resolvedUserProfile\.github\agents"
}

Write-Host "Installed $installedCount Copilot customization file copies."
Write-Host 'Restart Copilot Chat or the IDE if the new customizations are not detected immediately.'
