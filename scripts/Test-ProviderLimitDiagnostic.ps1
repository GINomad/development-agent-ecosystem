[CmdletBinding()]
param(
    [AllowEmptyString()][string] $Diagnostic
)

Set-StrictMode -Version Latest
$providerLimitPattern = '(?i)quota|rate[- ]?limit|limit reached|capacity|too many requests|usage limit|individual spend limit|spend(?:ing)? limit'
$executionRetryLimitPattern = '(?i)^execution retry limit reached after\s+\d+\s+identical failures:'
$taskState = $null
if ($Diagnostic.TrimStart().StartsWith('{')) {
    try { $taskState = $Diagnostic | ConvertFrom-Json -ErrorAction Stop } catch {}
}
$isSerializedTaskState = $null -ne $taskState -and $taskState.PSObject.Properties['taskId'] -and $taskState.PSObject.Properties['agentStatuses']
return (-not $isSerializedTaskState -and -not ($Diagnostic -match $executionRetryLimitPattern) -and $Diagnostic -match $providerLimitPattern)
