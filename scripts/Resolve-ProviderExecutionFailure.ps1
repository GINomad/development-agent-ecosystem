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
$isProviderLimit = [bool](& (Join-Path $PSScriptRoot 'Test-ProviderLimitDiagnostic.ps1') -Diagnostic $diagnostic)

[pscustomobject]@{
    ShouldThrow = $true
    IsProviderLimit = $isProviderLimit
    Message = if ($isProviderLimit) { $diagnostic } else { "$Provider exited with code $ExitCode. See $LogPath" }
}
