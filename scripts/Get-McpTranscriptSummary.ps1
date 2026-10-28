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
$transportFailedServers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$accessDeniedServers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$insideAttempt = $false
# The local server records actual calls for every provider, including Claude and
# Copilot whose transcript formats differ from Codex. Never double-count both.
$metricsPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) 'mcp-metrics.jsonl'
if (Test-Path -LiteralPath $metricsPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($metricsPath)) {
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if (-not $record -or -not $record.PSObject.Properties['attemptId'] -or
            [string]$record.attemptId -ne $AttemptId -or -not $record.PSObject.Properties['server'] -or [string]$record.server -ne $Server -or
            -not $record.PSObject.Properties['tool'] -or -not [string]$record.tool -or
            -not $record.PSObject.Properties['status'] -or
            [string]$record.status -notin @('succeeded','failed')) { continue }
        $callCount++
        if ([string]$record.status -eq 'succeeded') { $succeededCount++ }
        else {
            $null = $failedServers.Add($Server)
            if ($record.PSObject.Properties['errorClass'] -and [string]$record.errorClass -eq 'transport-or-protocol') { $null = $transportFailedServers.Add($Server) }
            if ($record.PSObject.Properties['errorClass'] -and [string]$record.errorClass -eq 'access-or-contract') { $null = $accessDeniedServers.Add($Server) }
        }
    }
}
$serverCallCount = $callCount
$serverSucceededCount = $succeededCount
$callCount = 0
$succeededCount = 0
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
        if ($failed) {
            if ($serverName) { $null = $failedServers.Add($serverName) }
            $errorText = if ($call.PSObject.Properties['error'] -and $call.error) { [string]$call.error } else { '' }
            if ($errorText -match '(?i)(artifact|source|tool) is not (public|allowed) for this role|MCP session .*?(integrity|binding|lease|task)|requested path escapes task root|(artifact|source|context pack) revision changed') { $null = $accessDeniedServers.Add($serverName) }
        }
        else { $succeededCount++ }
    }
}
$transcriptFailedCount = $callCount - $succeededCount
$serverFailedCount = $serverCallCount - $serverSucceededCount
# A client-side failure absent from the server log can be a broken transport.
# Preserve that failure even if earlier calls reached the local server.
if ($transcriptFailedCount -gt $serverFailedCount) { $null = $transportFailedServers.Add($Server) }
$succeededCount = [Math]::Max($succeededCount, $serverSucceededCount)
$failedCount = [Math]::Max($transcriptFailedCount, $serverFailedCount)
$callCount = $succeededCount + $failedCount
[pscustomobject]@{AttemptId=$AttemptId;Server=$Server;CallCount=$callCount;SucceededCallCount=$succeededCount;FailedCallCount=$failedCount;FailedServers=@($failedServers);TransportFailedServers=@($transportFailedServers);AccessDeniedServers=@($accessDeniedServers)}
