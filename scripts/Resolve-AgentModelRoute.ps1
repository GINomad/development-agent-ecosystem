[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [AllowEmptyString()][string] $TaskSelector = '',
    [AllowEmptyString()][string] $UserInstruction = '',
    [string[]] $RepositoryIds = @(),
    [string[]] $ChangedArtifactNames = @(),
    [switch] $HealthRecoveryRetry,
    [switch] $NoPersist,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$routing = $config.modelRouting
if (-not [bool]$routing.enabled) { throw 'modelRouting must be enabled for workflow execution.' }

$agent = @($config.agents | Where-Object { [string]$_.id -eq $AgentId }) | Select-Object -First 1
if (-not $agent) { throw "Unknown model-routing agent '$AgentId'." }
$policy = @($routing.rolePolicies | Where-Object { [string]$_.agentId -eq $AgentId }) | Select-Object -First 1
if (-not $policy) { throw "Missing model-routing role policy for '$AgentId'." }

$tiers = @($routing.tiers | Sort-Object { [int]$_.rank })
$tierById = @{}
foreach ($tier in $tiers) { $tierById[[string]$tier.id] = $tier }
foreach ($tierId in @([string]$policy.minimumTier, [string]$policy.defaultTier, [string]$policy.maximumTier)) {
    if (-not $tierById.ContainsKey($tierId)) { throw "Role policy for '$AgentId' references unknown tier '$tierId'." }
}
$minimumRank = [int]$tierById[[string]$policy.minimumTier].rank
$maximumRank = [int]$tierById[[string]$policy.maximumTier].rank
$selectedRank = [int]$tierById[[string]$policy.defaultTier].rank
if ($minimumRank -gt $selectedRank -or $selectedRank -gt $maximumRank) { throw "Role policy tiers are out of order for '$AgentId'." }

$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$taskRoot = Join-Path $stateRoot "tasks\$TaskId"
if (-not (Test-Path -LiteralPath $taskRoot -PathType Container)) { throw "Task '$TaskId' was not found." }

$maxEvidenceCharacters = [int]$routing.maxEvidenceCharacters
$evidence = [Text.StringBuilder]::new()
function Add-BoundedEvidence {
    param([AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $evidence.Length -ge $maxEvidenceCharacters) { return }
    $remaining = $maxEvidenceCharacters - $evidence.Length
    $value = if ($Text.Length -gt $remaining) { $Text.Substring(0, $remaining) } else { $Text }
    [void]$evidence.AppendLine($value)
}

Add-BoundedEvidence -Text $TaskSelector
Add-BoundedEvidence -Text $UserInstruction
$ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
    Add-BoundedEvidence -Text ((Get-Content -LiteralPath $ledgerPath -Tail ([int]$config.runtime.contextLimits.ledgerTailLines) -Encoding UTF8) -join [Environment]::NewLine)
}
foreach ($artifactName in @('requirements-analysis.json', 'implementation-plan.json', 'review-result.json', 'pipeline-result.json', 'health-check-result.json')) {
    $artifactPath = Join-Path $taskRoot $artifactName
    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) { Add-BoundedEvidence -Text (Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8) }
}

$signals = [Collections.Generic.List[string]]::new()
function Add-Signal {
    param([Parameter(Mandatory)][string] $Value)
    if (-not $signals.Contains($Value)) { $signals.Add($Value) }
}
Add-Signal -Value "role-default:$([string]$policy.defaultTier)"

$complexTierRank = [int]$tierById['complex'].rank
$criticalTierRank = [int]$tierById['critical'].rank
$repositoryValues = [string[]]@($RepositoryIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
$repositoryCount = [int](($repositoryValues | Measure-Object).Count)
$changedArtifactValues = [string[]]@($ChangedArtifactNames)
$changedArtifactCount = [int](($changedArtifactValues | Measure-Object).Count)
if ($repositoryCount -gt 1) {
    $selectedRank = [Math]::Max($selectedRank, $complexTierRank)
    Add-Signal -Value "multiple-repositories:$repositoryCount"
}
if ($evidence.Length -ge [int]$routing.largeEvidenceCharacters) {
    $selectedRank++
    Add-Signal -Value "large-bounded-context:$($evidence.Length)"
}
if ($changedArtifactCount -ge 5) {
    $selectedRank = [Math]::Max($selectedRank, $complexTierRank)
    Add-Signal -Value "many-changed-artifacts:$changedArtifactCount"
}

$matchedComplex = [string[]]@($routing.complexSignals | Where-Object { $evidence.ToString().IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
$matchedComplexCount = [int](($matchedComplex | Measure-Object).Count)
if ($matchedComplexCount) {
    $selectedRank = [Math]::Max($selectedRank, $complexTierRank)
    Add-Signal -Value ('complex-signals:' + (($matchedComplex | Select-Object -First 3) -join ','))
}
$matchedCritical = [string[]]@($routing.criticalSignals | Where-Object { $evidence.ToString().IndexOf([string]$_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
$matchedCriticalCount = [int](($matchedCritical | Measure-Object).Count)
if ($matchedCriticalCount) {
    $selectedRank = [Math]::Max($selectedRank, $criticalTierRank)
    Add-Signal -Value ('critical-signals:' + (($matchedCritical | Select-Object -First 3) -join ','))
}

$taskStatePath = Join-Path $taskRoot 'task.json'
$priorAgentStatus = ''
if (Test-Path -LiteralPath $taskStatePath -PathType Leaf) {
    $taskState = Get-Content -LiteralPath $taskStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentStatusProperty = $taskState.agentStatuses.PSObject.Properties[$AgentId]
    if ($agentStatusProperty) { $priorAgentStatus = [string]$agentStatusProperty.Value.status }
}
if ($priorAgentStatus -eq 'failed') {
    $selectedRank++
    Add-Signal -Value 'prior-agent-failure'
}
if ($HealthRecoveryRetry) {
    $selectedRank++
    Add-Signal -Value 'post-health-repair-retry'
}

$unclampedRank = $selectedRank
$selectedRank = [Math]::Max($minimumRank, [Math]::Min($maximumRank, $selectedRank))
if ($selectedRank -ne $unclampedRank) { Add-Signal -Value "role-policy-clamp:$unclampedRank->$selectedRank" }
$selectedTier = @($tiers | Where-Object { [int]$_.rank -eq $selectedRank }) | Select-Object -First 1
if (-not $selectedTier) { throw "No configured model tier has rank $selectedRank." }

$fingerprintMaterial = @(
    $AgentId,
    ($RepositoryIds -join ','),
    ($ChangedArtifactNames -join ','),
    [string][bool]$HealthRecoveryRetry,
    ($routing | ConvertTo-Json -Depth 20 -Compress),
    $evidence.ToString(),
    $priorAgentStatus
) -join "`n"
$sha = [Security.Cryptography.SHA256]::Create()
try { $inputFingerprint = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintMaterial)))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }

$artifactPath = Join-Path $taskRoot ([string]$routing.artifactName)
$document = $null
if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
    try { $document = Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Existing model-routing artifact is invalid: $($_.Exception.Message)" }
}
$existing = [object[]]@()
if ($document) { $existing = [object[]]@($document.decisions | Where-Object { [string]$_.agentId -eq $AgentId -and [string]$_.inputFingerprint -eq $inputFingerprint } | Select-Object -Last 1) }
$existingCount = [int](($existing | Measure-Object).Count)
if ($existingCount) {
    return [pscustomobject][ordered]@{
        decisionId = [string]$existing[0].decisionId
        agentId = $AgentId
        complexity = [string]$existing[0].complexity
        model = [string]$existing[0].model
        reasoningEffort = [string]$existing[0].reasoningEffort
        confidence = [double]$existing[0].confidence
        signals = @($existing[0].signals)
        inputFingerprint = $inputFingerprint
        reused = $true
        artifactPath = $artifactPath
    }
}

$confidence = if ($matchedCriticalCount -or $matchedComplexCount -or $repositoryCount -gt 1) { 0.95 } elseif ($evidence.Length -ge [int]$routing.largeEvidenceCharacters) { 0.85 } else { 0.90 }
$decision = [pscustomobject][ordered]@{
    decisionId = [guid]::NewGuid().ToString('N')
    agentId = $AgentId
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    complexity = [string]$selectedTier.id
    model = [string]$selectedTier.model
    reasoningEffort = [string]$selectedTier.reasoningEffort
    confidence = $confidence
    signals = @($signals)
    inputFingerprint = $inputFingerprint
    evidenceCharacterCount = [int]$evidence.Length
    repositoryCount = $repositoryCount
    changedArtifactCount = $changedArtifactCount
}

if (-not $NoPersist) {
    $decisions = [object[]]@($decision)
    if ($document) { $decisions = [object[]](@($document.decisions) + @($decision)) }
    $maxDecisions = [int]$routing.maxDecisionsPerTask
    $decisionCount = [int](($decisions | Measure-Object).Count)
    if ($decisionCount -gt $maxDecisions) { $decisions = [object[]]@($decisions | Select-Object -Last $maxDecisions) }
    $output = [ordered]@{ schemaVersion='1.0'; taskId=$TaskId; updatedAtUtc=[DateTime]::UtcNow.ToString('o'); latestDecisionId=$decision.decisionId; decisions=@($decisions) }
    $temporaryPath = "$artifactPath.tmp"
    Write-Utf8NoBom -Path $temporaryPath -Content (($output | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    Move-Item -LiteralPath $temporaryPath -Destination $artifactPath -Force
}

[pscustomobject][ordered]@{
    decisionId = [string]$decision.decisionId
    agentId = $AgentId
    complexity = [string]$decision.complexity
    model = [string]$decision.model
    reasoningEffort = [string]$decision.reasoningEffort
    confidence = [double]$decision.confidence
    signals = @($decision.signals)
    inputFingerprint = $inputFingerprint
    reused = $false
    artifactPath = $artifactPath
}
