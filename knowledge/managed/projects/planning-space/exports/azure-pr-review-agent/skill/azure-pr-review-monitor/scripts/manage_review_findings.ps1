[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [ValidateSet('Interactive','List','Bypass','FalsePositive','Restore','Publish')][string] $Action = 'Interactive',
    [string] $FindingId,
    [string] $ReviewPath,
    [ValidateSet('repository','pull-request')][string] $Scope = 'repository',
    [string] $Reason,
    [string] $ExpiresAt,
    [string] $DataRoot = (Join-Path $env:LOCALAPPDATA 'Codex\azure-pr-review-monitor'),
    [switch] $ForcePublish
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'review_findings_common.ps1')
. (Join-Path $PSScriptRoot 'agent_config.ps1')
. (Join-Path $PSScriptRoot 'providers\provider_dispatch.ps1')
$configPath = Join-Path $DataRoot 'config.json'
$config = Read-AgentConfig -Path $configPath -Migrate
if ([string]::IsNullOrWhiteSpace($ReviewPath)) {
    $statePath = Join-Path $DataRoot 'state.json'
    if (-not (Test-Path $statePath)) { throw 'No review path was supplied and state.json was not found.' }
    $state = Get-Content -Raw $statePath | ConvertFrom-Json
    $latest = @($state.pullRequests.PSObject.Properties | ForEach-Object { $_.Value } | Sort-Object reviewedAtUtc -Descending | Select-Object -First 1)
    if (-not $latest -or -not $latest[0].reportPath) { throw 'No completed review exists in state.json.' }
    $ReviewPath = [string]$latest[0].reportPath
}
$sidecarPath = [IO.Path]::ChangeExtension($ReviewPath, '.findings.json')
if (-not (Test-Path $sidecarPath)) { throw "Finding metadata was not found at $sidecarPath. Run or force a review with the updated agent first." }
$sidecar = Get-Content -Raw $sidecarPath | ConvertFrom-Json
if (-not $sidecar.provider) { $sidecar | Add-Member -NotePropertyName provider -NotePropertyValue 'azure-devops' -Force }
$findings = @($sidecar.findings)
if ($findings.Count -eq 0) { Write-Output 'The review contains no findings.'; exit 0 }

function Show-Findings {
    for ($index=0; $index -lt $findings.Count; $index++) {
        $finding = $findings[$index]
        Write-Host ("[{0}] {1} {2} {3}:{4} ({5})" -f ($index+1),$finding.FindingId,$finding.Severity,$finding.File,$finding.Line,$finding.Disposition)
        Write-Host "    $($finding.Title)"
    }
}

function Select-Finding {
    if ($FindingId) {
        $selected = @($findings | Where-Object { [string]::Equals([string]$_.FindingId,$FindingId,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if (-not $selected) { throw "Finding $FindingId was not found in $sidecarPath." }
        return $selected
    }
    Show-Findings
    $selection = Read-Host 'Select finding number'; $number = 0
    if (-not [int]::TryParse($selection,[ref]$number) -or $number -lt 1 -or $number -gt $findings.Count) { throw 'Invalid finding selection.' }
    return $findings[$number-1]
}

$interactiveMode = $Action -eq 'Interactive'
if ($Action -eq 'List') { Show-Findings; exit 0 }
if ($interactiveMode) {
    Show-Findings; $selection = Read-Host 'Select finding number'; $number = 0
    if (-not [int]::TryParse($selection,[ref]$number) -or $number -lt 1 -or $number -gt $findings.Count) { throw 'Invalid finding selection.' }
    $FindingId = [string]$findings[$number-1].FindingId
    $choice = (Read-Host 'Action: [B]ypass, [F]alse positive, [R]estore, [P]ublish').Trim().ToUpperInvariant()
    $Action = switch ($choice) { 'B' {'Bypass'} 'F' {'FalsePositive'} 'R' {'Restore'} 'P' {'Publish'} default { throw 'Invalid action.' } }
    if ($Action -in @('Bypass','FalsePositive')) {
        $scopeChoice = (Read-Host 'Scope: [R]epository or [P]ull request').Trim().ToUpperInvariant()
        $Scope = if ($scopeChoice -eq 'P') { 'pull-request' } else { 'repository' }
    }
}
$finding = Select-Finding
$repositoryName = [string]$sidecar.repository
$repositoryKey = if ($sidecar.dispositionRepository) { [string]$sidecar.dispositionRepository } elseif ($sidecar.repositoryConfigId) { "$($sidecar.provider)/$($sidecar.repositoryConfigId)" } else { $repositoryName }
$pullRequestId = [int]$sidecar.pullRequestId
$dispositionsPath = Join-Path $DataRoot 'finding-dispositions.json'

if ($Action -in @('Bypass','FalsePositive')) {
    if ([string]::IsNullOrWhiteSpace($Reason) -and $interactiveMode) { $Reason = Read-Host 'Reason (required)' }
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'A reason is required.' }
    if (-not $PSBoundParameters.ContainsKey('ExpiresAt') -and $Action -eq 'Bypass' -and $interactiveMode) { $ExpiresAt = Read-Host 'Expiration date (optional, e.g. 2026-12-31)' }
    if ($ExpiresAt) { $parsedDate=[DateTime]::MinValue; if(-not [DateTime]::TryParse($ExpiresAt,[ref]$parsedDate)){throw 'ExpiresAt is not a valid date.'} }
    $items = [Collections.Generic.List[object]]::new(); foreach ($item in @(Read-ReviewDispositions $dispositionsPath)) { $items.Add($item) }
    $dispositionValue = if ($Action -eq 'Bypass') { 'bypass' } else { 'false-positive' }
    $items.Add([pscustomobject][ordered]@{ findingId=[string]$finding.FindingId;rule=[string]$finding.Rule;filePattern=[string]$finding.File;repository=$repositoryKey;scope=$Scope;pullRequestId=$(if($Scope -eq 'pull-request'){$pullRequestId}else{0});disposition=$dispositionValue;reason=$Reason;expiresAt=$ExpiresAt;createdAt=(Get-Date).ToUniversalTime().ToString('o') })
    Write-ReviewDispositions $dispositionsPath $items
    $finding.Disposition = $dispositionValue; $finding.DispositionReason = $Reason
    [IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Write-Output "$($finding.FindingId) marked as $dispositionValue with $Scope scope."; exit 0
}

if ($Action -eq 'Restore') {
    $items = @(Read-ReviewDispositions $dispositionsPath | Where-Object {
        -not ([string]::Equals([string]$_.repository,$repositoryKey,[StringComparison]::OrdinalIgnoreCase) -and ([string]::Equals([string]$_.findingId,[string]$finding.FindingId,[StringComparison]::OrdinalIgnoreCase) -or ([string]::Equals([string]$_.rule,[string]$finding.Rule,[StringComparison]::OrdinalIgnoreCase) -and [string]$finding.File -like [string]$_.filePattern)))
    })
    Write-ReviewDispositions $dispositionsPath $items
    $finding.Disposition = 'actionable'; $finding.DispositionReason = ''
    [IO.File]::WriteAllText($sidecarPath, ($sidecar | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Write-Output "$($finding.FindingId) restored."; exit 0
}

if ($Action -ne 'Publish') { throw "Unsupported action $Action." }
$repository = if ($sidecar.repositoryConfigId) { @($config.repositories | Where-Object { $_.id -eq $sidecar.repositoryConfigId }) | Select-Object -First 1 } else { @($config.repositories | Where-Object { $_.provider -eq $sidecar.provider -and $_.repository -eq $repositoryName }) | Select-Object -First 1 }
if (-not $repository) { throw "No configured repository matches finding sidecar '$sidecarPath'." }
$profile = Get-AgentCredentialProfile -Config $config -Repository $repository
$publishedPath = Join-Path $DataRoot 'published-comments.json'
$published = if(Test-Path $publishedPath){Get-Content -Raw $publishedPath|ConvertFrom-Json}else{[pscustomobject]@{version=2;items=@()}}
$duplicate = @($published.items | Where-Object { $_.provider -eq $sidecar.provider -and $_.repositoryConfigId -eq $repository.id -and $_.pullRequestId -eq $pullRequestId -and $_.findingId -eq $finding.FindingId -and $_.sourceCommit -eq $sidecar.sourceCommit })
if($duplicate.Count -gt 0 -and -not $ForcePublish){throw "This finding was already published for the same source commit. Use -ForcePublish only when a duplicate comment is intentional."}
$comment = "**Codex review [$($finding.Severity)] $($finding.Title)**`n`n$($finding.Comment)`n`n**Why it matters:** $($finding.Why)`n`n**Recommendation:** $($finding.Recommendation)`n`nFinding ID: ``$($finding.FindingId)``"
if($PSCmdlet.ShouldProcess("$($sidecar.provider) PR $pullRequestId $($finding.File):$($finding.Line)","Publish finding $($finding.FindingId)")){
    $temporary=Join-Path $DataRoot "publish-$([Guid]::NewGuid().ToString('N')).json"
    try {
        $response = Publish-ProviderFinding -Repository $repository -Profile $profile -Sidecar $sidecar -Finding $finding -Comment $comment -TemporaryPath $temporary
        $items=@($published.items)+@([pscustomobject][ordered]@{provider=[string]$sidecar.provider;repositoryConfigId=[string]$repository.id;pullRequestId=$pullRequestId;repository=$repositoryName;findingId=[string]$finding.FindingId;sourceCommit=[string]$sidecar.sourceCommit;externalId=[string]$response.id;url=[string]$response.url;publishedAtUtc=(Get-Date).ToUniversalTime().ToString('o')})
        [ordered]@{version=2;items=$items}|ConvertTo-Json -Depth 8|Set-Content $publishedPath -Encoding UTF8
        Write-Output "Published $($finding.FindingId) to $($sidecar.provider) as comment $($response.id)."
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
