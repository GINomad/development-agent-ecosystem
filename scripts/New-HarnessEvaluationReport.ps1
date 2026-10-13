[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $ProjectId,
    [ValidateRange(2,100)][int] $MinimumCohortSize = 2,
    [string] $OutputPath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$tasksRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'tasks'

function Read-Json([string]$Path) { if (Test-Path -LiteralPath $Path -PathType Leaf) { try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } }
function Read-JsonLines([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }; @([IO.File]::ReadLines($Path) | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { try { $_ | ConvertFrom-Json } catch { } } }) }
function Get-Long($Value) { $number=0L; if ($null -ne $Value -and [long]::TryParse([string]$Value,[ref]$number) -and $number -ge 0) { $number } else { 0L } }
function Get-Duration($Task) { try { [long]([DateTime]::Parse([string]$Task.updatedAtUtc).ToUniversalTime() - [DateTime]::Parse([string]$Task.createdAtUtc).ToUniversalTime()).TotalMilliseconds } catch { 0L } }
function Get-Sum([object[]]$Records,[string]$Property){$sum=0L;foreach($record in @($Records)){$sum+=Get-Long $record.$Property};$sum}
function Get-Metrics([object[]]$Records) {
    $criteriaTotal=[int](Get-Sum $Records criteriaTotal); $criteriaVerified=[int](Get-Sum $Records criteriaVerified)
    $totalDuration=[long](Get-Sum $Records durationMs)
    [pscustomobject][ordered]@{
        taskCount=$Records.Count; evaluableTaskCount=@($Records | Where-Object evaluationStatus -eq 'evaluable').Count
        criteriaTotal=$criteriaTotal; criteriaVerified=$criteriaVerified; criteriaCompletionRate=if($criteriaTotal){[Math]::Round($criteriaVerified/$criteriaTotal,4)}else{$null}
        falseCompletionCount=@($Records | Where-Object falseCompletion).Count
        humanInterventionCount=[int](Get-Sum $Records humanInterventions); failureCount=[int](Get-Sum $Records failures)
        recoveryCount=[int](Get-Sum $Records recoveries); totalDurationMs=$totalDuration; averageDurationMs=if($Records.Count){[long]($totalDuration/$Records.Count)}else{$null}
        totalTokens=[long](Get-Sum $Records totalTokens); unavailableUsageRecordCount=[int](Get-Sum $Records unavailableUsageRecords)
    }
}

$taskEvaluations=[Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
    foreach($directory in @(Get-ChildItem -LiteralPath $tasksRoot -Directory)) {
        $task=Read-Json (Join-Path $directory.FullName 'task.json'); if(-not $task){continue}
        $taskProject=if($task.PSObject.Properties['projectId']){[string]$task.projectId}else{''}; if($ProjectId -and $taskProject -ne $ProjectId){continue}
        $requirements=Read-Json (Join-Path $directory.FullName 'requirements-analysis.json')
        $review=Read-Json (Join-Path $directory.FullName 'review-result.json')
        $summary=Read-Json (Join-Path $directory.FullName 'task-summary.json')
        $routing=Read-Json (Join-Path $directory.FullName 'model-routing.json')
        $ledger=@(Read-JsonLines (Join-Path $directory.FullName 'task-ledger.jsonl'))
        $tokens=@(Read-JsonLines (Join-Path $directory.FullName 'token-usage.jsonl'))
        $scenarios=if($requirements -and $requirements.PSObject.Properties['verificationScenarios']){@($requirements.verificationScenarios)}else{@()}
        $verifiedScenarioCandidates=@(if($review){$review.requirementTraceability | ForEach-Object { if($_.PSObject.Properties['scenarioResults']){@($_.scenarioResults | Where-Object verdict -eq 'verified' | ForEach-Object {[string]$_.scenarioId})} }})
        $verifiedScenarioIds=@($verifiedScenarioCandidates | Select-Object -Unique)
        $criteriaTotal=$scenarios.Count; $criteriaVerified=@($scenarios | Where-Object { [string]$_.id -in $verifiedScenarioIds }).Count
        $completed=[string]$task.status -eq 'completed'; $falseCompletion=$completed -and $criteriaTotal -gt 0 -and ($criteriaVerified -lt $criteriaTotal -or -not $summary)
        $human=@($ledger | Where-Object { [string]$_.actor -eq 'user' -and [string]$_.type -in @('user-comment','question-resolved','review-decision','task-reopened','task-close-requested') }).Count
        $failures=@($ledger | Where-Object type -eq 'agent-failure').Count
        $recoveries=@($ledger | Where-Object { [string]$_.actor -eq 'health_check' -and [string]$_.type -in @('agent-result','continuation-reconciled','workflow-status') }).Count
        $reported=@($tokens | Where-Object { [string]$_.availability -in @('reported','partial') -and $null -ne $_.totalTokens })
        $totalTokens=0L; foreach($record in $reported){$totalTokens+=Get-Long $record.totalTokens}
        $modelParts=[Collections.Generic.List[string]]::new()
        if($routing){foreach($decision in @($routing.decisions)){ $modelParts.Add("$([string]$decision.agentId)=$([string]$decision.model)/$([string]$decision.reasoningEffort)") }}
        if(-not $modelParts.Count){foreach($record in $tokens){if($record.model){$modelParts.Add("$([string]$record.agentId)=$([string]$record.provider)/$([string]$record.model)")}}}
        $modelSignature=(@($modelParts | Sort-Object -Unique) -join ';')
        $budgetSignature=if($routing){(@($routing.decisions | Where-Object { $_.PSObject.Properties['contextBudgetSignature'] } | ForEach-Object { [string]$_.contextBudgetSignature } | Sort-Object -Unique) -join ';')}else{''}
        $evidence=@('task.json','requirements-analysis.json','review-result.json','task-ledger.jsonl','token-usage.jsonl','model-routing.json')
        $taskEvaluations.Add([pscustomobject][ordered]@{
            taskId=[string]$task.taskId; projectId=$taskProject; status=[string]$task.status
            evaluationStatus=if($criteriaTotal -and $modelSignature -and $budgetSignature){'evaluable'}else{'contract-metadata-missing'}; criteriaTotal=$criteriaTotal; criteriaVerified=$criteriaVerified
            falseCompletion=[bool]$falseCompletion; humanInterventions=$human; failures=$failures; recoveries=$recoveries; durationMs=Get-Duration $task
            totalTokens=$totalTokens; unavailableUsageRecords=$tokens.Count-$reported.Count; modelSignature=$modelSignature; budgetSignature=$budgetSignature; evidence=$evidence
        })
    }
}
$tasks=@($taskEvaluations)
$cohorts=@($tasks | Group-Object { "$($_.modelSignature)|$($_.budgetSignature)" } | ForEach-Object { $members=@($_.Group); [pscustomobject][ordered]@{key=[string]$_.Name;comparable=$members.Count -ge $MinimumCohortSize -and -not [string]::IsNullOrWhiteSpace([string]$members[0].modelSignature);taskIds=@($members.taskId);metrics=Get-Metrics $members} })
$report=[pscustomobject][ordered]@{
    schemaVersion='1.0'; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); projectId=if($ProjectId){$ProjectId}else{$null}
    comparisonPolicy=[pscustomobject][ordered]@{modelSignature='exact provider/model/reasoning per role';budgetSignature='configured context limits';minimumCohortSize=$MinimumCohortSize}
    summary=Get-Metrics $tasks; tasks=$tasks; cohorts=$cohorts
}
if($OutputPath){$resolved=[IO.Path]::GetFullPath($OutputPath);$parent=Split-Path -Parent $resolved;if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null};Write-Utf8NoBom -Path $resolved -Content (($report|ConvertTo-Json -Depth 20)+[Environment]::NewLine)}
$report
