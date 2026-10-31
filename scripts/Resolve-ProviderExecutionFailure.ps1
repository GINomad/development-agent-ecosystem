[CmdletBinding()]
param(
    [Parameter(Mandatory)][int] $ExitCode,
    [Parameter(Mandatory)][string] $Provider,
    [Parameter(Mandatory)][string] $LogPath,
    [AllowEmptyString()][string] $FailureDetail,
    [AllowEmptyString()][string] $Reason
)

Set-StrictMode -Version Latest

if ($ExitCode -eq 0) {
    return [pscustomobject]@{ ShouldThrow = $false; IsProviderLimit = $false; Message = $null }
}

$diagnostic = (@($FailureDetail, $Reason) | Where-Object { $_ }) -join ' '
$classification = & (Join-Path $PSScriptRoot 'Get-ProviderFailureClassification.ps1') -Diagnostic $diagnostic
$isProviderLimit = [bool]$classification.IsProviderLimit

[pscustomobject]@{
    ShouldThrow = $true
    IsProviderLimit = $isProviderLimit
    IsExternal = [bool]$classification.IsExternal
    FailureCategory = [string]$classification.Category
    Message = if ([bool]$classification.IsExternal) { $diagnostic } else { "$Provider exited with code $ExitCode. See $LogPath" }
}
