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
$copilotCalls = @{}
if (Test-Path -LiteralPath $Path -PathType Leaf) {
    foreach ($line in [IO.File]::ReadLines($Path)) {
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $entry -or -not $entry.PSObject.Properties['type']) { continue }
        if ([string]$entry.type -eq 'ecosystem-workflow-run') {
            $copilotCalls = @{}
            $insideAttempt = [string]$entry.attemptId -eq $AttemptId
            continue
        }
        if (-not $insideAttempt) { continue }
        if ([string]$entry.type -eq 'tool.execution_start' -and $entry.PSObject.Properties['data']) {
            $data=$entry.data
            if ($data.PSObject.Properties['mcpServerName'] -and [string]$data.mcpServerName -eq $Server) { $copilotCalls[[string]$data.toolCallId]=$Server }
            continue
        }
        if ([string]$entry.type -eq 'tool.execution_complete' -and $entry.PSObject.Properties['data']) {
            $data=$entry.data
            if ($copilotCalls.ContainsKey([string]$data.toolCallId)) {
                $callCount++
                if ($data.PSObject.Properties['success'] -and [bool]$data.success) { $succeededCount++ } else { $null=$failedServers.Add($Server) }
                $copilotCalls.Remove([string]$data.toolCallId)
            }
            continue
        }
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
