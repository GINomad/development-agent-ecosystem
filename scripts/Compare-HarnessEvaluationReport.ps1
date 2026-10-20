[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BaselinePath,
    [Parameter(Mandatory)][string] $TreatmentPath,
    [string] $OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$baseline = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$treatment = Get-Content -LiteralPath $TreatmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($report in @($baseline,$treatment)) {
    if ($report.schemaVersion -ne '2.0') { throw 'Comparison requires v2 snapshots; regenerate legacy measurements.' }
}
if (-not $baseline.cohortLabel -or $baseline.cohortLabel -ne $treatment.cohortLabel -or $baseline.practiceVersion -eq $treatment.practiceVersion) {
    throw 'Use the same explicit cohort label and distinct practice versions.'
}
if ([DateTimeOffset]::Parse($baseline.generatedAtUtc) -ge [DateTimeOffset]::Parse($treatment.generatedAtUtc)) { throw 'Baseline must precede treatment.' }
if ($baseline.collectorSha256 -cne $treatment.collectorSha256) { throw 'Use snapshots from the same collector revision.' }
$overlap = @($baseline.tasks | Where-Object { $_.taskId -in @($treatment.tasks | ForEach-Object { $_.taskId }) })
if ($overlap.Count) { throw 'A task cannot be in both baseline and treatment.' }
$comparisons = @($treatment.cohorts | ForEach-Object {
    $after = $_
    $matches = @($baseline.cohorts | Where-Object { $_.key -eq $after.key -and $_.comparable })
    if (-not $after.comparable -or $matches.Count -ne 1 -or $after.metrics.taskCount -lt 3 -or $matches[0].metrics.taskCount -lt 3) { return }
    $before = $matches[0]; $deltas = [ordered]@{}; $ready = $true; $improved = $false; $regression = $false
    foreach ($field in @('averageDurationMs','totalTokens','humanInterventionCount','failureCount','artifactBytes','contextBytes')) {
        $left = $before.metrics.$field; $right = $after.metrics.$field
        if ($null -eq $left -or $null -eq $right) { $ready = $false; $deltas[$field] = $null; continue }
        if ($field -ne 'averageDurationMs') { $left /= $before.metrics.taskCount; $right /= $after.metrics.taskCount }
        $delta = if ($left -gt 0) { [Math]::Round(($right - $left) / $left,4) } elseif ($right -eq 0) { 0 } else { $null }
        $deltas[$field] = $delta
        if ($field -in @('averageDurationMs','totalTokens','humanInterventionCount') -and $null -ne $delta -and $delta -le -0.1) { $improved = $true }
        if (($field -in @('artifactBytes','contextBytes') -and $right -gt 1.2 * $left) -or ($field -eq 'failureCount' -and $right -gt $left)) { $regression = $true }
    }
    $quality = $null -ne $after.metrics.falseCompletionCount -and $after.metrics.falseCompletionCount -eq 0 -and
        $after.metrics.criteriaCompletionRate -eq 1 -and $after.metrics.requirementLinkRate -eq 1
    [pscustomobject]@{
        key=$after.key; baselineTasks=$before.taskIds; treatmentTasks=$after.taskIds; relativeChanges=[pscustomobject]$deltas
        verdict=if(-not $ready){'awaiting-data'}elseif(-not $quality -or $regression){'regressed'}elseif($improved){'promising'}else{'no-demonstrated-benefit'}
    }
})
$result = [pscustomobject]@{
    schemaVersion='1.0'; baselineSha256=(Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
    treatmentSha256=(Get-FileHash -LiteralPath $TreatmentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    status=if($comparisons.Count){'evaluated'}else{'awaiting-data'}; comparisons=$comparisons
    limitation='Observational pilot, not a causal or statistical significance claim. Prices are not inferred from token counts.'
}
if ($OutputPath) {
    if (Test-Path -LiteralPath $OutputPath) { throw 'Comparison snapshot already exists.' }
    $json = ($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,(New-Object Text.UTF8Encoding($false)))
}
$result
