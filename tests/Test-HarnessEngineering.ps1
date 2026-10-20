[CmdletBinding()]
param([string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\harness-engineering'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'));$state=Join-Path $fixture 'state';New-Item -ItemType Directory -Path $state -Force|Out-Null
$config=Get-Content (Join-Path $root 'config\agents.json') -Raw|ConvertFrom-Json;$config.runtime.stateRoot=$state;$configPath=Join-Path $fixture 'agents.json';Write-Utf8NoBom -Path $configPath -Content (($config|ConvertTo-Json -Depth 100)+[Environment]::NewLine)
$head=(& git -C $root rev-parse HEAD).Trim()
function Write-Json([string]$Path,$Value){$parent=Split-Path -Parent $Path;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null};Write-Utf8NoBom -Path $Path -Content (($Value|ConvertTo-Json -Depth 30)+[Environment]::NewLine)}
function Write-Lines([string]$Path,[object[]]$Values){Write-Utf8NoBom -Path $Path -Content ((@($Values|ForEach-Object{$_|ConvertTo-Json -Compress})-join [Environment]::NewLine)+[Environment]::NewLine)}
foreach($number in 1..2){
 $taskId="harness-$number";$taskRoot=Join-Path $state "tasks\$taskId";New-Item -ItemType Directory -Path $taskRoot -Force|Out-Null
 Write-Json (Join-Path $taskRoot 'task.json') ([ordered]@{taskId=$taskId;projectId='planning-space';taskType='Task';repositoryIds=@('ecosystem');status='completed';createdAtUtc='2026-10-12T10:00:00Z';updatedAtUtc="2026-10-12T1$number`:00:00Z"})
 Write-Json (Join-Path $taskRoot 'requirements-analysis.json') ([ordered]@{practiceVersion='legacy';requirements=@([ordered]@{id='REQ-A';status='ready';acceptanceScenarioIds=@('SCN-A','SCN-B')});verificationScenarios=@([ordered]@{id='SCN-A';requirementIds=@('REQ-A')},[ordered]@{id='SCN-B';requirementIds=@('REQ-A')})})
 $secondVerdict=if($number -eq 1){'verified'}else{'failed'}
 Write-Json (Join-Path $taskRoot 'review-result.json') ([ordered]@{reviewedRevision=$head;requirementTraceability=@([ordered]@{scenarioResults=@([ordered]@{scenarioId='SCN-A';verdict='verified';commit=$head;evidence=@('test A')},[ordered]@{scenarioId='SCN-B';verdict=$secondVerdict;commit=$head;evidence=@('test B')})})})
 Write-Json (Join-Path $taskRoot 'review-verification.json') ([ordered]@{verificationStatus='passed';reviewedRevision=$head;reviewArtifactSha256=(Get-FileHash (Join-Path $taskRoot 'review-result.json') -Algorithm SHA256).Hash.ToLowerInvariant()})
 Write-Json (Join-Path $taskRoot 'implementation-result.json') ([ordered]@{headCommit=$head;scenarioResults=@([ordered]@{scenarioId='SCN-A';status='passed';commit=$head;evidence=@('test A')},[ordered]@{scenarioId='SCN-B';status='passed';commit=$head;evidence=@('test B')})})
 if($number -eq 1){Write-Json (Join-Path $taskRoot 'task-summary.json') ([ordered]@{taskId=$taskId;status='completed';completedAtUtc='2026-10-12T11:00:00Z'})}
 Write-Json (Join-Path $taskRoot 'model-routing.json') ([ordered]@{decisions=@([ordered]@{agentId='developer';model='gpt-test';reasoningEffort='medium';contextBudgetSignature=('a'*64)})})
 Write-Lines (Join-Path $taskRoot 'token-usage.jsonl') @([ordered]@{agentId='developer';provider='codex';model='gpt-test';availability='reported';totalTokens=150})
 Write-Json (Join-Path $taskRoot 'provider-routing.json') ([ordered]@{decisions=@([ordered]@{agentId='developer';provider='codex';model='gpt-test';reasoningEffort='medium'})})
 Write-Lines (Join-Path $taskRoot 'workflow-routing.jsonl') @([ordered]@{executionMode='full-delivery'})
 $events=@(if($number -eq 1){@([ordered]@{actor='user';type='review-decision'},[ordered]@{actor='developer';type='agent-failure'},[ordered]@{actor='health_check';type='agent-result'})}else{@()});if($events.Count){Write-Lines (Join-Path $taskRoot 'task-ledger.jsonl') $events}
}
$knowledgeRoot=Join-Path $state 'tasks\harness-1'
Write-Json (Join-Path $knowledgeRoot 'knowledge-update.json') ([ordered]@{entries=@(
 [ordered]@{id='KN-CURRENT';owner='platform-team';sourceBindings=@([ordered]@{repositoryId='ecosystem';path='README.md';revision=$head});revalidation=[ordered]@{lastVerifiedAtUtc='2026-10-12T10:00:00Z';triggers=@('source-revision-changed')}},
 [ordered]@{id='KN-STALE';owner='platform-team';sourceBindings=@([ordered]@{repositoryId='ecosystem';path='README.md';revision=('0'*40)});revalidation=[ordered]@{lastVerifiedAtUtc='2026-10-12T10:00:00Z';triggers=@('source-revision-changed')}},
 [ordered]@{id='KN-LEGACY'}
)})
$evaluation=& (Join-Path $root 'scripts\New-HarnessEvaluationReport.ps1') -ProjectId planning-space -MinimumCohortSize 2 -CohortLabel fixture -ConfigPath $configPath
if($evaluation.summary.taskCount -ne 2 -or $evaluation.summary.criteriaTotal -ne 4 -or $evaluation.summary.criteriaVerified -ne 3 -or $evaluation.summary.falseCompletionCount -ne 1 -or $null -ne $evaluation.summary.humanInterventionCount -or $evaluation.tasks[0].humanInterventions -ne 1 -or $evaluation.tasks[0].failures -ne 1 -or $evaluation.tasks[0].recoveries -ne 1 -or $evaluation.summary.totalTokens -ne 300){throw 'Harness evaluation metrics are incorrect.'}
if(@($evaluation.cohorts).Count -ne 1 -or -not @($evaluation.cohorts)[0].comparable){throw 'Comparable model/budget cohort was not formed.'}
$freshness=& (Join-Path $root 'scripts\Get-KnowledgeFreshnessReport.ps1') -ProjectId planning-space -RepositoryRoots @{ecosystem=$root} -ConfigPath $configPath
if($freshness.summary.currentCount -ne 1 -or $freshness.summary.staleCount -ne 1 -or $freshness.summary.metadataMissingCount -ne 1){throw 'Knowledge freshness classification is incorrect.'}
$contractRoot=Join-Path $state 'tasks\contract-gate';New-Item -ItemType Directory -Path $contractRoot -Force|Out-Null
$contract=[ordered]@{taskId='contract-gate';requirements=@([ordered]@{id='REQ-1';acceptanceScenarioIds=@('SCN-1')});verificationScenarios=@([ordered]@{id='SCN-1';requirementIds=@('REQ-1');acceptanceCriterion='Observable result';preconditions=@();steps=@('Run focused test');expectedOutcome='Test passes';evidenceRequired=@('test output')})}
$contractPath=Join-Path $contractRoot 'requirements-analysis.json';Write-Json $contractPath $contract
& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId contract-gate -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $contractPath -TaskRoot $contractRoot | Out-Null
$contract.requirements[0].acceptanceScenarioIds=@('SCN-MISSING');Write-Json $contractPath $contract;$rejected=$false;try{& (Join-Path $root 'scripts\Test-AgentOutcomeArtifact.ps1') -TaskId contract-gate -AgentId requirements_analyst -ArtifactName requirements-analysis.json -Path $contractPath -TaskRoot $contractRoot|Out-Null}catch{$rejected=$_.Exception.Message -match 'known verification scenarios'};if(-not $rejected){throw 'Requirements publication accepted an unknown scenario link.'}
foreach($schema in @('requirements-analysis','implementation-result','review-result','knowledge-update','harness-evaluation-report','knowledge-freshness-report')){Get-Content (Join-Path $root "config\schemas\$schema.schema.json") -Raw|ConvertFrom-Json|Out-Null}
[pscustomobject]@{Status='passed';Checks=5;OutputRoot=$fixture}
