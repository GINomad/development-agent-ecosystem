[CmdletBinding()]
param([string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\specification-practices'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
$state=Join-Path $fixture 'state'
New-Item -ItemType Directory -Path $state -Force | Out-Null
$config=Get-Content (Join-Path $root 'config\agents.json') -Raw | ConvertFrom-Json
$config.runtime.stateRoot=$state
$configPath=Join-Path $fixture 'agents.json'
function Json([string]$Path,$Object) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Write-Utf8NoBom -Path $Path -Content (($Object | ConvertTo-Json -Depth 60)+[Environment]::NewLine)
}
function Lines([string]$Path,[object[]]$Objects) { Write-Utf8NoBom -Path $Path -Content ((@($Objects | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join [Environment]::NewLine)+[Environment]::NewLine) }
function Reject([scriptblock]$Action,[string]$Pattern) {
    $caught=$false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -match $Pattern) { $caught=$true } else { throw } }
    if (-not $caught) { throw "Expected rejection: $Pattern" }
}
Json $configPath $config
$commit='a'*40
function New-FixtureTask([string]$Id,[int]$Tokens=100,[string]$Provider='codex',[string]$PracticeVersion='legacy') {
    $path=Join-Path $state ('tasks\'+$Id)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Json (Join-Path $path 'task.json') @{taskId=$Id;projectId='planning-space';status='completed';taskType='Task';repositoryIds=@('ecosystem');createdAtUtc='2026-10-01T10:00:00Z'}
    Json (Join-Path $path 'requirements-analysis.json') @{taskId=$Id;practiceVersion=$PracticeVersion;requirements=@(@{id='REQ-1';status='ready';acceptanceScenarioIds=@('SCN-1')});verificationScenarios=@(@{id='SCN-1';requirementIds=@('REQ-1');acceptanceCriterion='Observable result';preconditions=@();steps=@('Run test');expectedOutcome='Pass';evidenceRequired=@('test output')})}
    Json (Join-Path $path 'implementation-result.json') @{headCommit=$commit;scenarioResults=@(@{scenarioId='SCN-1';status='passed';commit=$commit;evidence=@('ran test')})}
    Json (Join-Path $path 'review-result.json') @{reviewedRevision=$commit;requirementTraceability=@(@{scenarioResults=@(@{scenarioId='SCN-1';verdict='verified';commit=$commit;evidence=@('review test')})})}
    Json (Join-Path $path 'review-verification.json') @{verificationStatus='passed';reviewedRevision=$commit;reviewArtifactSha256=(Get-FileHash (Join-Path $path 'review-result.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
    Json (Join-Path $path 'task-summary.json') @{completedAtUtc='2026-10-01T11:00:00Z'}
    Json (Join-Path $path 'model-routing.json') @{decisions=@(@{agentId='developer';contextBudgetSignature=('b'*64)})}
    Json (Join-Path $path 'provider-routing.json') @{decisions=@(@{agentId='developer';provider=$Provider;model='same-name';reasoningEffort='medium'})}
    Json (Join-Path $path 'context-pack.json') @{context='fixed'}
    Lines (Join-Path $path 'workflow-routing.jsonl') @(@{executionMode='full-delivery'})
    Lines (Join-Path $path 'token-usage.jsonl') @(@{agentId='developer';provider=$Provider;model='same-name';availability='reported';totalTokens=$Tokens})
    Lines (Join-Path $path 'task-ledger.jsonl') @(@{actor='orchestrator';type='task-created'})
    Lines (Join-Path $path 'role-metrics.jsonl') @(@{eventType='role-attempt-completed';agentId='developer';durationMs=123})
    return $path
}
$paths=@(1..3 | ForEach-Object { New-FixtureTask ('before'+$_) })
$reportScript=Join-Path $root 'scripts\New-HarnessEvaluationReport.ps1'
$baselinePath=Join-Path $fixture 'baseline.json'
$baseline=& $reportScript -TaskIds before1,before2,before3 -PracticeVersion legacy -CohortLabel fixture -OutputPath $baselinePath -ConfigPath $configPath
if (-not $baseline.cohorts[0].comparable -or $baseline.summary.criteriaVerified -ne 3 -or $baseline.summary.falseCompletionCount -ne 0 -or $baseline.tasks[0].stageDurations[0].durationMs -ne 123 -or $baseline.summary.requirementLinkRate -ne 1) { throw 'Complete baseline metrics failed.' }
if (Get-Command Test-Json -ErrorAction SilentlyContinue) { Get-Content $baselinePath -Raw | Test-Json -SchemaFile (Join-Path $root 'config\schemas\harness-evaluation-report.schema.json') -ErrorAction Stop | Out-Null }
Reject { & $reportScript -OutputPath $baselinePath -ConfigPath $configPath } 'already exists'
Reject { & $reportScript -TaskIds nonexistent -ConfigPath $configPath } 'Selected tasks missing'
foreach ($number in 1..3) { $null=New-FixtureTask ('after'+$number) 80 -PracticeVersion spec-practices-1.0.0 }
$treatmentPath=Join-Path $fixture 'treatment.json'
$treatment=& $reportScript -TaskIds after1,after2,after3 -PracticeVersion spec-practices-1.0.0 -CohortLabel fixture -OutputPath $treatmentPath -ConfigPath $configPath
$comparison=& (Join-Path $root 'scripts\Compare-HarnessEvaluationReport.ps1') -BaselinePath $baselinePath -TreatmentPath $treatmentPath
if ($comparison.status -ne 'evaluated' -or $comparison.comparisons[0].verdict -ne 'promising') { throw 'Comparable pilot benefit not detected.' }
$mislabeled=& $reportScript -TaskIds before1,before2,before3 -PracticeVersion spec-practices-1.0.0 -CohortLabel fixture -ConfigPath $configPath
if (@($mislabeled.cohorts | Where-Object comparable).Count) { throw 'Snapshot relabeled legacy tasks as treatment.' }
Reject { & (Join-Path $root 'scripts\Compare-HarnessEvaluationReport.ps1') -BaselinePath $baselinePath -TreatmentPath $baselinePath } 'distinct practice versions'

$null=New-FixtureTask other-provider 100 copilot
$split=& $reportScript -TaskIds before1,before2,other-provider -CohortLabel fixture -ConfigPath $configPath
if ($split.cohorts.Count -ne 2 -or @($split.cohorts | Where-Object comparable).Count) { throw 'Providers were incorrectly pooled.' }
$first=$paths[0]
Json (Join-Path $first 'review-verification.json') @{verificationStatus='passed';reviewedRevision=$commit;reviewArtifactSha256=('0'*64)}
$stale=& $reportScript -TaskIds before1 -ConfigPath $configPath
if ($stale.tasks[0].criteriaVerified -ne 0 -or -not $stale.tasks[0].falseCompletion) { throw 'Stale verifier granted completion.' }
$null=New-FixtureTask before1
Json (Join-Path $first 'implementation-result.json') @{headCommit=('c'*40);scenarioResults=@(@{scenarioId='SCN-1';status='passed';commit=('c'*40);evidence=@('test')})}
$stale=& $reportScript -TaskIds before1 -ConfigPath $configPath
if ($stale.tasks[0].criteriaVerified -ne 0) { throw 'Mismatched final commit granted completion.' }
$null=New-FixtureTask before1
Lines (Join-Path $first 'token-usage.jsonl') @(@{agentId='developer';provider='codex';model='same-name';availability='partial';totalTokens=10})
$partial=& $reportScript -TaskIds before1 -CohortLabel fixture -ConfigPath $configPath
if ($null -ne $partial.summary.totalTokens -or $partial.summary.unavailableUsageRecordCount -ne 1 -or $partial.cohorts[0].comparable) { throw 'Partial usage was treated as complete.' }
Lines (Join-Path $first 'token-usage.jsonl') @(@{agentId='developer';provider='codex';model='same-name';availability='reported';totalTokens='not-a-count'})
$malformed=& $reportScript -TaskIds before1 -ConfigPath $configPath
if ($null -ne $malformed.summary.totalTokens -or $malformed.summary.unavailableUsageRecordCount -ne 1) { throw 'Malformed token count was accepted.' }
$null=New-FixtureTask before1
$held=Get-Content (Join-Path $first 'requirements-analysis.json') -Raw | ConvertFrom-Json
$held.requirements+=@([pscustomobject]@{id='REQ-HELD';status='held';acceptanceScenarioIds=@('SCN-HELD')})
$held.verificationScenarios+=@([pscustomobject]@{id='SCN-HELD';requirementIds=@('REQ-HELD')})
Json (Join-Path $first 'requirements-analysis.json') $held
$heldReport=& $reportScript -TaskIds before1 -ConfigPath $configPath
if ($heldReport.summary.criteriaTotal -ne 1 -or $heldReport.summary.falseCompletionCount -ne 0) { throw 'Held scope was counted as false completion.' }
$null=New-FixtureTask before1
Json (Join-Path $first 'model-routing.json') @{decisions=@(@{agentId='developer'})}
$missing=& $reportScript -TaskIds before1 -CohortLabel fixture -ConfigPath $configPath
if ($missing.tasks[0].evaluationStatus -eq 'evaluable') { throw 'Missing budget accepted.' }
Write-Utf8NoBom -Path (Join-Path $first 'task-ledger.jsonl') -Content 'corrupt'
$missing=& $reportScript -TaskIds before1 -ConfigPath $configPath
if ($null -ne $missing.summary.humanInterventionCount) { throw 'Corrupt ledger became zero.' }

# Assessment stays inside the existing requirements outcome and persisted research mode.
$assessmentPath=New-FixtureTask assessment
$requirements=Get-Content (Join-Path $assessmentPath 'requirements-analysis.json') -Raw | ConvertFrom-Json
$requirements | Add-Member plan @()
$requirements | Add-Member questions @()
$requirements | Add-Member humanReadable ([pscustomobject]@{implementationPlan=@()})
$assessment=[pscustomobject]@{problem='Existing evidence supports a bounded idea';successCriteria=@('Observe outcome');evidence=@([pscustomobject]@{source='first-party revision';observation='Observed need';confidence='observed'});evidenceAgainst=@('Cost of maintaining extra documents');alternatives=@(@{option='Do nothing';tradeoff='No new cost';appetite='zero'},@{option='Small pilot';tradeoff='Bounded evidence';appetite='one day'});evidenceQuality='adequate';verdict='go';rationale='Pilot is justified';handoff='Request implementation separately'}
$requirements | Add-Member ideaAssessment $assessment
$requirementsPath=Join-Path $assessmentPath 'requirements-analysis.json'
Lines (Join-Path $assessmentPath 'workflow-routing.jsonl') @(@{executionMode='research-only'})
Json $requirementsPath $requirements
$validator=Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1'
& $validator -TaskId assessment -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $requirementsPath -TaskRoot $assessmentPath | Out-Null
$research=& $reportScript -TaskIds assessment -CohortLabel fixture -ConfigPath $configPath
if ($null -ne $research.tasks[0].falseCompletion -or $research.cohorts[0].comparable) { throw 'Research was evaluated as delivery.' }
$assessment.evidenceQuality='weak';Json $requirementsPath $requirements
Reject { & $validator -TaskId assessment -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $requirementsPath -TaskRoot $assessmentPath } 'go verdict requires'
$assessment.verdict='needs-clarification';Json $requirementsPath $requirements
& $validator -TaskId assessment -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $requirementsPath -TaskRoot $assessmentPath | Out-Null
Lines (Join-Path $assessmentPath 'workflow-routing.jsonl') @(@{executionMode='full-delivery'})
Reject { & $validator -TaskId assessment -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $requirementsPath -TaskRoot $assessmentPath } 'research-only routing'

$export=& (Join-Path $root 'scripts\Export-PracticeBundle.ps1') -OutputPath (Join-Path $fixture 'practices.zip')
if ($export.assetCount -lt 5) { throw 'Practice bundle is incomplete.' }
$expanded=Join-Path $fixture 'expanded';Expand-Archive -LiteralPath $export.path -DestinationPath $expanded
$manifest=Get-Content (Join-Path $expanded 'practice-bundle.json') -Raw | ConvertFrom-Json
foreach ($asset in $manifest.assets) { if ((Get-FileHash (Join-Path $expanded $asset.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) { throw 'Exported asset differs.' } }
$manifest.assets[0].sha256='0'*64;$badManifest=Join-Path $fixture 'bad-manifest.json';Json $badManifest $manifest
Reject { & (Join-Path $root 'scripts\Export-PracticeBundle.ps1') -ManifestPath $badManifest -OutputPath (Join-Path $fixture 'bad.zip') } 'digest mismatch'
$manifest.assets[0].path='plugins/development-agent-ecosystem/skills/analyze-requirements/../../../../config/agents.json';Json $badManifest $manifest
Reject { & (Join-Path $root 'scripts\Export-PracticeBundle.ps1') -ManifestPath $badManifest -OutputPath (Join-Path $fixture 'bad.zip') } 'Invalid or duplicate'
foreach ($provider in @('codex','copilot','claude')) {
    $installRoot=Join-Path $fixture $provider
    $installed=& (Join-Path $root 'scripts\Install-ChatOnlyAgents.ps1') -Provider $provider -DestinationRoot $installRoot -ConfigPath $configPath
    if (-not (Test-Path (Join-Path $installRoot 'skills\analyze-requirements\assets\specification.md'))) { throw "Missing practice assets: $provider" }
    $again=& (Join-Path $root 'scripts\Install-ChatOnlyAgents.ps1') -Provider $provider -DestinationRoot $installRoot -ConfigPath $configPath
    if (@($again.Written).Count -or -not @($again.Unchanged).Count) { throw 'Native installation is not idempotent.' }
    $editedGuide=Join-Path $installRoot 'skills\analyze-requirements\assets\specification.md'
    Write-Utf8NoBom -Path $editedGuide -Content 'User edit'
    Reject { & (Join-Path $root 'scripts\Install-ChatOnlyAgents.ps1') -Provider $provider -DestinationRoot $installRoot -ConfigPath $configPath } 'Refusing to overwrite'
    if ((Get-Content $editedGuide -Raw) -ne 'User edit') { throw 'Native installation lost a user edit.' }
}
[pscustomobject]@{Status='passed';Checks=26;OutputRoot=$fixture}
