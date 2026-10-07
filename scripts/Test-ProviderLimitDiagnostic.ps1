[CmdletBinding()]
param(
    [AllowEmptyString()][string] $Diagnostic
)

Set-StrictMode -Version Latest
$providerLimitPattern = '(?i)quota|rate[- ]?limit|limit reached|capacity|too many requests|usage limit|individual spend limit|spend(?:ing)? limit'
$executionRetryLimitPattern = '(?i)^execution retry limit reached after\s+\d+\s+identical failures:'
return (-not ($Diagnostic -match $executionRetryLimitPattern) -and $Diagnostic -match $providerLimitPattern)