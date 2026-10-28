[CmdletBinding()]
param([AllowEmptyString()][string] $Diagnostic)

Set-StrictMode -Version Latest

$text = [string]$Diagnostic

# A role/session contract rejection is actionable task context, not a broken MCP
# transport. Never open a circuit or recursively restart a role for it.
if ($text -match '(?i)(artifact|source|tool) is not (public|allowed) for this role|MCP session .*?(integrity|binding|lease|task)|MCP session agent is not actively running|requested path escapes task root|(artifact|source|context pack) revision changed|MCP role call limit|MCP response exceeds') {
    return [pscustomobject]@{ Kind = 'access-or-contract'; Retryable = $false }
}

if ($text -match '(?i)\bmcp\b.*?(transport|protocol|connection|timeout|unavailable|broken pipe)|\b(transport|protocol)\b|tools/list') {
    return [pscustomobject]@{ Kind = 'transport-or-protocol'; Retryable = $true }
}

[pscustomobject]@{ Kind = 'other'; Retryable = $false }
