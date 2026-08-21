[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $RecipientAgentId,
    [string[]] $ArtifactNames = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$agent = @($config.agents | Where-Object { [string]$_.id -eq $RecipientAgentId }) | Select-Object -First 1
if (-not $agent) { throw "Unknown context-pack recipient '$RecipientAgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$contextPath = Join-Path $taskRoot 'context-pack.json'
$existing = $null
if (Test-Path -LiteralPath $contextPath -PathType Leaf) {
    try { $existing = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $existing = $null }
}

$selectedSkills = [Collections.Generic.List[string]]::new()
foreach ($skillPath in @($agent.skillPaths)) {
    $normalized = ([string]$skillPath).Replace('/', '\')
    $skillName = Split-Path -Leaf (Split-Path -Parent $normalized)
    if ($skillName -and -not $selectedSkills.Contains($skillName)) { $selectedSkills.Add($skillName) }
}
if (-not $selectedSkills.Count) { $selectedSkills.Add([string]$agent.id) }

$artifactSummaries = [Collections.Generic.List[object]]::new()
$artifactSources = [Collections.Generic.List[object]]::new()
foreach ($nameValue in @($ArtifactNames | Select-Object -Unique)) {
    $name = [string]$nameValue
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ([IO.Path]::GetFileName($name) -ne $name) { throw "Context artifact must be a direct task artifact: $name" }
    $path = Join-Path $taskRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Context artifact '$name' is missing." }
    $file = Get-Item -LiteralPath $path
    $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $summary = ''
    if ([IO.Path]::GetExtension($name).Equals('.json', [StringComparison]::OrdinalIgnoreCase)) {
        try {
            $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($propertyName in @('summary','objective','description','rootCause','nextAction')) {
                if ($document.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$document.$propertyName)) {
                    $summary = [string]$document.$propertyName
                    break
                }
            }
        }
        catch { throw "Context artifact '$name' is not valid JSON: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "Stable task artifact '$name' ($($file.Length) bytes)." }
    if ($summary.Length -gt 1000) { $summary = $summary.Substring(0, 1000) }
    $artifactSummaries.Add([pscustomobject][ordered]@{
        name = $name
        sha256 = $sha256
        summary = $summary
        updatedAtUtc = $file.LastWriteTimeUtc.ToString('o')
    })
    $artifactSources.Add([pscustomobject][ordered]@{
        kind = 'history'
        location = $path
        revision = $sha256
        reason = "Stable artifact supplied to '$RecipientAgentId' without reopening unchanged content."
    })
}

$taskView = & (Join-Path $PSScriptRoot 'Get-AgentTasks.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
$openQuestions = @($taskView.Tasks[0].openQuestions | ForEach-Object {
    if ($_.PSObject.Properties['question']) { [string]$_.question } elseif ($_.PSObject.Properties['summary']) { [string]$_.summary }
} | Where-Object { $_ })
$heldScope = if ($existing -and $existing.PSObject.Properties['heldScope']) { @($existing.heldScope | ForEach-Object { [string]$_ }) } else { @() }
$detectedStack = if ($existing -and $existing.PSObject.Properties['engineeringGuidance']) { @($existing.engineeringGuidance.detectedStack | ForEach-Object { [string]$_ }) } else { @() }
$acceptedKnowledge = if ($existing -and $existing.PSObject.Properties['acceptedKnowledge']) { @($existing.acceptedKnowledge) } else { @() }
$preservedSources = if ($existing -and $existing.PSObject.Properties['sources']) { @($existing.sources | Where-Object { [string]$_.kind -eq 'knowledge' }) } else { @() }

$pack = [ordered]@{
    taskId = $TaskId
    recipient = $RecipientAgentId
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    sources = @($preservedSources) + @($artifactSources)
    acceptedKnowledge = @($acceptedKnowledge)
    artifactSummaries = @($artifactSummaries)
    engineeringGuidance = [ordered]@{
        detectedStack = @($detectedStack)
        selectedSkills = @($selectedSkills)
        reason = "Configured skills for '$RecipientAgentId'; the trusted host did not infer additional stack knowledge."
    }
    openQuestions = @($openQuestions)
    heldScope = @($heldScope)
}
Write-Utf8NoBom -Path $contextPath -Content (($pack | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

$validated = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$validated.taskId -ne $TaskId -or [string]$validated.recipient -ne $RecipientAgentId) { throw 'Context pack identity validation failed.' }
if (-not $validated.PSObject.Properties['artifactSummaries'] -or -not $validated.PSObject.Properties['engineeringGuidance'] -or -not @($validated.engineeringGuidance.selectedSkills).Count) { throw 'Context pack required presentation or skill fields are missing.' }
foreach ($expected in $artifactSummaries) {
    $actual = @($validated.artifactSummaries | Where-Object { [string]$_.name -eq [string]$expected.name }) | Select-Object -First 1
    if (-not $actual -or [string]$actual.sha256 -ne [string]$expected.sha256) { throw "Context pack fingerprint validation failed for '$([string]$expected.name)'." }
}
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor knowledge_keeper -Type context-issued -Summary "Validated context pack issued to '$RecipientAgentId' with $($artifactSummaries.Count) stable artifact summary item(s)." -Artifact $contextPath -Evidence @($artifactSummaries | ForEach-Object { "artifact:$([string]$_.name):$([string]$_.sha256)" }) -TargetAgentId $RecipientAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{ TaskId=$TaskId; RecipientAgentId=$RecipientAgentId; ContextPath=$contextPath; ArtifactCount=$artifactSummaries.Count }
