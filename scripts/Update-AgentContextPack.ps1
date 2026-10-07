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
$existingSummaries = @{}
if ($existing -and $existing.PSObject.Properties['artifactSummaries']) {
    foreach ($item in @($existing.artifactSummaries)) {
        if ($item.PSObject.Properties['name'] -and $item.PSObject.Properties['sha256']) {
            $existingSummaries[[string]$item.name] = $item
        }
    }
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
    $sha256 = Get-EcosystemFileSha256 -Path $path
    $priorSummary = if ($existingSummaries.ContainsKey($name) -and [string]$existingSummaries[$name].sha256 -eq $sha256) { $existingSummaries[$name] } else { $null }
    if ($priorSummary) {
        $summary = [string]$priorSummary.summary
        $updatedAtUtc = if ($priorSummary.updatedAtUtc -is [DateTime]) { ([DateTime]$priorSummary.updatedAtUtc).ToUniversalTime().ToString('o') } else { [string]$priorSummary.updatedAtUtc }
    }
    else {
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
        $updatedAtUtc = $file.LastWriteTimeUtc.ToString('o')
    }
    $artifactSummaries.Add([pscustomobject][ordered]@{
        name = $name
        sha256 = $sha256
        summary = $summary
        updatedAtUtc = $updatedAtUtc
    })
    $artifactSources.Add([pscustomobject][ordered]@{
        kind = 'history'
        location = $path
        revision = $sha256
        reason = "Stable artifact supplied to '$RecipientAgentId' without reopening unchanged content."
    })
}

$taskView = & (Join-Path $PSScriptRoot 'Get-AgentTasks.ps1') -TaskId $TaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
$ledgerOpenQuestions = @($taskView.Tasks[0].openQuestions | ForEach-Object {
    if ($_.PSObject.Properties['question']) { [string]$_.question } elseif ($_.PSObject.Properties['summary']) { [string]$_.summary }
} | Where-Object { $_ })
$analysisOpenQuestions = [Collections.Generic.List[string]]::new()
$analysisHeldScope = [Collections.Generic.List[string]]::new()
$requirementsAnalysisPath = Join-Path $taskRoot 'requirements-analysis.json'
if (Test-Path -LiteralPath $requirementsAnalysisPath -PathType Leaf) {
    try { $requirementsAnalysis = Get-Content -LiteralPath $requirementsAnalysisPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Requirements analysis context source is not valid JSON: $($_.Exception.Message)" }
    foreach ($requirement in @($requirementsAnalysis.requirements | Where-Object { [string]$_.status -eq 'held' })) {
        $id = [string]$requirement.id
        $text = [string]$requirement.text
        if ($id) { $analysisHeldScope.Add((if ($text) { "${id}: $text" } else { $id })) }
    }
    foreach ($planItem in @($requirementsAnalysis.plan | Where-Object { [string]$_.status -eq 'held' })) {
        $id = [string]$planItem.id
        if ($id) {
            $requirementIds = @($planItem.requirementIds | ForEach-Object { [string]$_ } | Where-Object { $_ })
            $analysisHeldScope.Add((if ($requirementIds.Count) { "$id (requirements: $($requirementIds -join ', '))" } else { $id }))
        }
    }
    foreach ($question in @($requirementsAnalysis.questions | Where-Object { [string]$_.status -eq 'open' })) {
        $id = [string]$question.id
        $text = [string]$question.question
        if ($id -and $text) { $analysisOpenQuestions.Add("${id}: $text") }
    }
}
$openQuestions = @($ledgerOpenQuestions + @($analysisOpenQuestions) | Select-Object -Unique)
$existingHeldScope = if ($existing -and $existing.PSObject.Properties['heldScope']) { @($existing.heldScope | ForEach-Object { [string]$_ }) } else { @() }
$heldScope = @($existingHeldScope + @($analysisHeldScope) | Select-Object -Unique)
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

function ConvertTo-ContextPackIdentityJson {
    param([Parameter(Mandatory)] $Value)

    ([ordered]@{
        taskId = [string]$Value.taskId
        recipient = [string]$Value.recipient
        sources = @($Value.sources)
        acceptedKnowledge = @($Value.acceptedKnowledge)
        artifactSummaries = @($Value.artifactSummaries | ForEach-Object {
            [ordered]@{ name=[string]$_.name; sha256=[string]$_.sha256; summary=[string]$_.summary }
        })
        engineeringGuidance = $Value.engineeringGuidance
        openQuestions = @($Value.openQuestions)
        heldScope = @($Value.heldScope)
    } | ConvertTo-Json -Depth 20 -Compress)
}

if ($existing -and [string]$existing.recipient -eq $RecipientAgentId -and
    (ConvertTo-ContextPackIdentityJson -Value $existing) -eq (ConvertTo-ContextPackIdentityJson -Value ([pscustomobject]$pack))) {
    foreach ($expected in $artifactSummaries) {
        $actual = @($existing.artifactSummaries | Where-Object { [string]$_.name -eq [string]$expected.name }) | Select-Object -First 1
        if (-not $actual -or [string]$actual.sha256 -ne [string]$expected.sha256) { throw "Reused context pack fingerprint validation failed for '$([string]$expected.name)'." }
    }
    return [pscustomobject]@{ TaskId=$TaskId; RecipientAgentId=$RecipientAgentId; ContextPath=$contextPath; ArtifactCount=$artifactSummaries.Count; Reused=$true }
}

Write-Utf8NoBom -Path $contextPath -Content (($pack | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

$validated = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$validated.taskId -ne $TaskId -or [string]$validated.recipient -ne $RecipientAgentId) { throw 'Context pack identity validation failed.' }
if (-not $validated.PSObject.Properties['artifactSummaries'] -or -not $validated.PSObject.Properties['engineeringGuidance'] -or -not @($validated.engineeringGuidance.selectedSkills).Count) { throw 'Context pack required presentation or skill fields are missing.' }
foreach ($expected in $artifactSummaries) {
    $actual = @($validated.artifactSummaries | Where-Object { [string]$_.name -eq [string]$expected.name }) | Select-Object -First 1
    if (-not $actual -or [string]$actual.sha256 -ne [string]$expected.sha256) { throw "Context pack fingerprint validation failed for '$([string]$expected.name)'." }
}
foreach ($expected in @($analysisOpenQuestions)) {
    if ($validated.openQuestions -notcontains $expected) { throw "Context pack omitted requirements-analysis open question '$expected'." }
}
foreach ($expected in @($analysisHeldScope)) {
    if ($validated.heldScope -notcontains $expected) { throw "Context pack omitted requirements-analysis held scope '$expected'." }
}
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor knowledge_keeper -Type context-issued -Summary "Validated context pack issued to '$RecipientAgentId' with $($artifactSummaries.Count) stable artifact summary item(s)." -Artifact $contextPath -Evidence @($artifactSummaries | ForEach-Object { "artifact:$([string]$_.name):$([string]$_.sha256)" }) -TargetAgentId $RecipientAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{ TaskId=$TaskId; RecipientAgentId=$RecipientAgentId; ContextPath=$contextPath; ArtifactCount=$artifactSummaries.Count; Reused=$false }
