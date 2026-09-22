[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $AttemptId,
    [string] $Server = 'ecosystem-read'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$callCount = 0
$succeededCount = 0
$failedServers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$insideAttempt = $false
if (Test-Path -LiteralPath $Path -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($Path)) {
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ([string]$entry.type -eq 'ecosystem-workflow-run') {
            $insideAttempt = [string]$entry.attemptId -eq $AttemptId
            continue
        }
        if (-not $insideAttempt) { continue }
        $call = $null
        if ([string]$entry.type -eq 'mcp_tool_call') { $call = $entry }
        elseif ([string]$entry.type -eq 'item.completed' -and $entry.PSObject.Properties['item'] -and [string]$entry.item.type -eq 'mcp_tool_call') { $call = $entry.item }
        if (-not $call) { continue }
        $serverName = if ($call.PSObject.Properties['server']) { [string]$call.server } elseif ($call.PSObject.Properties['serverName']) { [string]$call.serverName } else { '' }
        if ($serverName -ne $Server) { continue }
        $callCount++
        $failed = ([string]$call.status -match '^(failed|error)$') -or [bool]($call.PSObject.Properties['isError'] -and $call.isError) -or [bool]($call.PSObject.Properties['error'] -and $call.error)
        if ($failed) { if ($serverName) { $null = $failedServers.Add($serverName) } }
        else { $succeededCount++ }
    }
}
[pscustomobject]@{AttemptId=$AttemptId;Server=$Server;CallCount=$callCount;SucceededCallCount=$succeededCount;FailedCallCount=($callCount-$succeededCount);FailedServers=@($failedServers)}
