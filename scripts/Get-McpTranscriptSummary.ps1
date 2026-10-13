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
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $entry) { continue }
        $entryType = if ($entry.PSObject.Properties['type']) { [string]$entry.type } else { '' }
        if ($entryType -eq 'ecosystem-workflow-run') {
            $entryAttemptId = if ($entry.PSObject.Properties['attemptId']) { [string]$entry.attemptId } else { '' }
            $insideAttempt = $entryAttemptId -eq $AttemptId
            continue
        }
        if (-not $insideAttempt) { continue }
        $call = $null
        if ($entryType -eq 'mcp_tool_call') { $call = $entry }
        elseif (
            $entryType -eq 'item.completed' -and
            $entry.PSObject.Properties['item'] -and
            $null -ne $entry.item -and
            $entry.item.PSObject.Properties['type'] -and
            [string]$entry.item.type -eq 'mcp_tool_call'
        ) { $call = $entry.item }
        if (-not $call) { continue }
        $serverName = if ($call.PSObject.Properties['server']) { [string]$call.server } elseif ($call.PSObject.Properties['serverName']) { [string]$call.serverName } else { '' }
        if ($serverName -ne $Server) { continue }
        $callCount++
        $callStatus = if ($call.PSObject.Properties['status']) { [string]$call.status } else { '' }
        $failed = ($callStatus -match '^(failed|error)$') -or [bool]($call.PSObject.Properties['isError'] -and $call.isError) -or [bool]($call.PSObject.Properties['error'] -and $call.error)
        if ($failed) { if ($serverName) { $null = $failedServers.Add($serverName) } }
        else { $succeededCount++ }
    }
}
[pscustomobject]@{AttemptId=$AttemptId;Server=$Server;CallCount=$callCount;SucceededCallCount=$succeededCount;FailedCallCount=($callCount-$succeededCount);FailedServers=@($failedServers)}
