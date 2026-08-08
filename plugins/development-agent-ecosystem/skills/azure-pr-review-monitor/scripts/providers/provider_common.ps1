function Find-AgentExecutable {
    param([Parameter(Mandatory)][string[]] $Names, [string] $ConfiguredPath)
    if ($ConfiguredPath -and (Test-Path -LiteralPath $ConfiguredPath)) { return $ConfiguredPath }
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    return $null
}

function Invoke-AgentNative {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $WorkingDirectory,
        [hashtable] $Environment
    )
    $previousLocation = Get-Location
    $savedEnvironment = @{}
    $environmentEntries = if ($Environment) { @($Environment.GetEnumerator()) } else { @() }
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        foreach ($entry in $environmentEntries) {
            $savedEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $FilePath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($exitCode -ne 0) { throw "$FilePath failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)" }
        return @($output)
    }
    finally {
        foreach ($entry in @($savedEnvironment.GetEnumerator())) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
        Set-Location -LiteralPath $previousLocation
    }
}

function Invoke-AgentJson {
    param([Parameter(Mandatory)][string] $FilePath, [Parameter(Mandatory)][string[]] $Arguments, [string] $WorkingDirectory, [hashtable] $Environment)
    $output = Invoke-AgentNative -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
    $json = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    return $json | ConvertFrom-Json
}

function Get-ProfileEnvironment {
    param([Parameter(Mandatory)] $Profile)
    if ($Profile.mode -notmatch 'environment') { return @{} }
    $name = [string]$Profile.environmentVariable
    if (-not $name) { throw "Credential profile '$($Profile.id)' requires environmentVariable." }
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'User') }
    if (-not $value) { throw "Environment variable '$name' is not set for credential profile '$($Profile.id)'." }
    if ($Profile.provider -eq 'github' -and $name -notin @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) { return @{ GH_TOKEN = $value } }
    if ($Profile.provider -eq 'azure-devops' -and $name -ne 'AZURE_DEVOPS_EXT_PAT') { return @{ AZURE_DEVOPS_EXT_PAT = $value } }
    return @{ $name = $value }
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string] $Value)
    return (($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-'))
}
