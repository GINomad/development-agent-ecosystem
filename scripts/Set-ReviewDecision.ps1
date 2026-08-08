[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^REV-[0-9]{3,}$')][string] $FindingId,
    [Parameter(Mandatory)][ValidateSet('approved','rejected','deferred')][string] $Decision,
    [Parameter(Mandatory)][string] $DecidedBy,
    [string] $Note = '',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$reviewPath = Join-Path $taskRoot 'review-result.json'
if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw "Review artifact was not found: $reviewPath" }
$review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json
$known = @($review.findings) + @($review.agentProcessFindings)
if (-not @($known | Where-Object { $_.id -eq $FindingId }).Count) { throw "Finding '$FindingId' does not exist in $reviewPath." }

$decisionsPath = Join-Path $taskRoot 'review-decisions.json'
$decisions = if (Test-Path -LiteralPath $decisionsPath) { Get-Content -LiteralPath $decisionsPath -Raw | ConvertFrom-Json } else { [pscustomobject][ordered]@{ taskId = $TaskId; decisions = @() } }
$entry = [pscustomobject][ordered]@{
    findingId = $FindingId
    decision = $Decision
    decidedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    decidedBy = $DecidedBy
    note = $Note
}
$decisions.decisions = @($decisions.decisions) + @($entry)
$temporary = "$decisionsPath.tmp"
Write-Utf8NoBom -Path $temporary -Content (($decisions | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
Move-Item -LiteralPath $temporary -Destination $decisionsPath -Force
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $DecidedBy -Type 'review-decision' -Summary "$FindingId was $Decision. $Note" -Artifact $decisionsPath -Evidence @($reviewPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$entry

