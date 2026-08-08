[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ReportPath,
    [Parameter(Mandatory)][string] $DispositionsPath,
    [Parameter(Mandatory)][string] $RepositoryName,
    [Parameter(Mandatory)][int] $PullRequestId,
    [Parameter(Mandatory)][string] $SourceCommit,
    [ValidateSet('azure-devops','github')][string] $Provider = 'azure-devops',
    [string] $RepositoryConfigId,
    [string] $RepositoryUrl,
    [string] $PullRequestUrl,
    [string] $DispositionRepository
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'review_findings_common.ps1')
$utf8 = New-Object Text.UTF8Encoding($false)
$content = [IO.File]::ReadAllText($ReportPath, $utf8)
$content = $content.Replace([char]0x2018, "'").Replace([char]0x2019, "'")
$content = $content.Replace([char]0x201C, '"').Replace([char]0x201D, '"')
$content = $content.Replace([char]0x2013, '-').Replace([char]0x2014, '-')
$content = $content.Replace([string][char]0x2026, '...').Replace([char]0x00A0, ' ')
if ($content -notmatch '(?m)^REVIEW_STATUS: COMPLETE\s*$') { throw 'Cannot process an incomplete review.' }
$findings = @(Get-ReviewFindings $content)
$dispositions = @(Read-ReviewDispositions $DispositionsPath)
$dispositionRepositoryValue = if ($DispositionRepository) { $DispositionRepository } else { $RepositoryName }
foreach ($finding in $findings) {
    $disposition = Get-ReviewDisposition -Finding $finding -Dispositions $dispositions -Repository $dispositionRepositoryValue -PullRequestId $PullRequestId
    if ($disposition) {
        $finding.Disposition = [string]$disposition.disposition
        $finding.DispositionReason = [string]$disposition.reason
    }
}
$additionalRiskMatch = [regex]::Match($content, '(?ms)^## Additional risks\s*(?<content>.*)$')
$additionalRisks = if ($additionalRiskMatch.Success) { $additionalRiskMatch.Groups['content'].Value.Trim() } else { '' }
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('REVIEW_STATUS: COMPLETE'); $lines.Add(''); $lines.Add('## Findings'); $lines.Add('')
$actionable = @($findings | Where-Object { $_.Disposition -eq 'actionable' })
if ($actionable.Count -eq 0) { $lines.Add('No actionable findings.'); $lines.Add('') }
foreach ($finding in $actionable) {
    $lines.Add("### [$($finding.Severity)] $($finding.Title)")
    $lines.Add("**Finding ID:** ``$($finding.FindingId)``")
    $lines.Add("**Rule:** ``$($finding.Rule)``")
    $lines.Add("**Location:** ``$($finding.File):$($finding.Line)``")
    $lines.Add("**Comment:** $($finding.Comment)")
    $lines.Add("**Why it matters:** $($finding.Why)")
    $lines.Add("**Recommendation:** $($finding.Recommendation)")
    $lines.Add('')
}
foreach ($group in @(@{Name='Bypassed findings';Value='bypass'},@{Name='False positives';Value='false-positive'})) {
    $items = @($findings | Where-Object { $_.Disposition -eq $group.Value })
    if ($items.Count -gt 0) {
        $lines.Add("## $($group.Name)"); $lines.Add('')
        foreach ($finding in $items) { $lines.Add("- ``$($finding.FindingId)`` [$($finding.Severity)] $($finding.Title) - $($finding.DispositionReason)") }
        $lines.Add('')
    }
}
if ($additionalRisks) { $lines.Add('## Additional risks'); $lines.Add(''); $lines.Add($additionalRisks); $lines.Add('') }
[IO.File]::WriteAllText($ReportPath, ($lines -join [Environment]::NewLine), $utf8)
$sidecarPath = [IO.Path]::ChangeExtension($ReportPath, '.findings.json')
$sidecar = [ordered]@{
    version=2; provider=$Provider; repositoryConfigId=$RepositoryConfigId; dispositionRepository=$dispositionRepositoryValue
    repository=$RepositoryName; repositoryUrl=$RepositoryUrl; pullRequestId=$PullRequestId
    pullRequestUrl=$PullRequestUrl; sourceCommit=$SourceCommit
    generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); findings=$findings
}
[IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Depth 8), $utf8)
Write-Output $sidecarPath
