[CmdletBinding()]
param([AllowNull()][AllowEmptyString()][string] $Diagnostic)
Set-StrictMode -Version Latest
# Explicit assertions include individual spend limit and spend(?:ing)? limit.
$classification = & (Join-Path $PSScriptRoot 'Get-ProviderFailureClassification.ps1') -Diagnostic $Diagnostic
return [bool]$classification.IsProviderLimit
