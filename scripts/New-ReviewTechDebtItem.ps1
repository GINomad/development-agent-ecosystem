[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^REV-[0-9]{3,}$')][string] $FindingId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Reason,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $CreatedBy,
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
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$finding = @(@($review.findings) + @($review.agentProcessFindings) | Where-Object { [string]$_.id -eq $FindingId }) | Select-Object -First 1
if (-not $finding) { throw "Finding '$FindingId' does not exist in $reviewPath." }

$debtPath = Join-Path $taskRoot 'tech-debt-items.json'
$document = if (Test-Path -LiteralPath $debtPath -PathType Leaf) { Get-Content -LiteralPath $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject][ordered]@{ taskId=$TaskId; items=@() } }
$existing = @($document.items | Where-Object { [string]$_.sourceFindingId -eq $FindingId }) | Select-Object -First 1
if ($existing) { return $existing }

$itemId = 'TD-' + $FindingId
$title = [string]$finding.impact
if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$finding.correctionDirection }
if ([string]::IsNullOrWhiteSpace($title)) { $title = "Reviewer finding $FindingId" }
if ($title.Length -gt 180) { $title = $title.Substring(0, 177) + '...' }
$item = [pscustomobject][ordered]@{
    id=$itemId; sourceFindingId=$FindingId; title=$title; status='open'
    severity=[string]$finding.severity; category=[string]$finding.category
    createdAtUtc=[DateTime]::UtcNow.ToString('o'); createdBy=$CreatedBy
    bypassReason=$Reason.Trim(); reviewArtifact=$reviewPath
    evidence=[string]$finding.evidence; impact=[string]$finding.impact
    correctionDirection=[string]$finding.correctionDirection
}
$document.items = @($document.items) + @($item)
$temporary = "$debtPath.tmp"
Write-Utf8NoBom -Path $temporary -Content (($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
Move-Item -LiteralPath $temporary -Destination $debtPath -Force
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor reviewer -Type 'tech-debt-created' -Summary "$itemId tracks bypassed Reviewer finding $FindingId. $($item.bypassReason)" -Artifact $debtPath -Evidence @("review-finding:$FindingId", "tech-debt-item:$itemId", $reviewPath) -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
$item
