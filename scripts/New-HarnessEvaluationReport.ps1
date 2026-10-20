[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $ProjectId,
    [ValidateRange(2,100)][int] $MinimumCohortSize = 3,
    [string[]] $TaskIds = @(),
    [string] $PracticeVersion = 'legacy',
    [string] $CohortLabel = '',
    [string] $OutputPath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$tasksRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'tasks'

function Value($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Read-Json([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
    }
}
function Read-Lines([string]$Path) {
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $line | ConvertFrom-Json }
    }
}
function Count-Events($Events, [string[]]$Types, [string]$Actor = '') {
    @($Events | Where-Object { (Value $_ 'type') -in $Types -and (-not $Actor -or (Value $_ 'actor') -eq $Actor) }).Count
}
function Sum-Observed([object[]]$Rows, [string]$Field) {
    if (-not $Rows.Count) { return $null }
    $sum = 0L
    foreach ($row in $Rows) {
        $value = Value $row $Field
        if ($value -is [bool]) { $value = [int]$value }
        $count = 0L
        if ($null -eq $value -or -not [long]::TryParse([string]$value,[ref]$count) -or $count -lt 0) { return $null }
        $sum += $count
    }
    return $sum
}
function Metrics([object[]]$Rows) {
    $fields = [ordered]@{
        criteriaTotal='criteriaTotal'; criteriaVerified='criteriaVerified'; falseCompletionCount='falseCompletion'
        humanInterventionCount='humanInterventions'; clarificationCount='clarifications'; failureCount='failures'
        recoveryCount='recoveries'; totalDurationMs='durationMs'; totalTokens='totalTokens'
        unavailableUsageRecordCount='unavailableUsageRecords'; requirementCount='requirementCount'
        linkedRequirementCount='linkedRequirementCount'; reviewReworkCount='reviewReworkCount'
        roleAttemptCount='roleAttemptCount'; artifactBytes='artifactBytes'; contextBytes='contextBytes'
    }
    $result = [ordered]@{taskCount=$Rows.Count; evaluableTaskCount=@($Rows | Where-Object evaluationStatus -eq 'evaluable').Count}
    $observed = [ordered]@{}
    foreach ($field in $fields.Keys) {
        $result[$field] = Sum-Observed $Rows $fields[$field]
        $observed[$field] = @($Rows | Where-Object { $null -ne (Value $_ $fields[$field]) }).Count
    }
    $result.criteriaCompletionRate = if ($result.criteriaTotal) { [Math]::Round($result.criteriaVerified / $result.criteriaTotal, 4) } else { $null }
    $result.requirementLinkRate = if ($result.requirementCount) { [Math]::Round($result.linkedRequirementCount / $result.requirementCount, 4) } else { $null }
    $result.averageDurationMs = if ($Rows.Count -and $null -ne $result.totalDurationMs) { [long]($result.totalDurationMs / $Rows.Count) } else { $null }
    $result.observedTaskCounts = [pscustomobject]$observed
    [pscustomobject]$result
}
$taskEvaluations = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $tasksRoot -Directory | Sort-Object Name)) {
        if ($TaskIds.Count -and $directory.Name -notin $TaskIds) { continue }
        $task = Read-Json (Join-Path $directory.FullName 'task.json')
        if (-not $task) { $skipped.Add($directory.Name); continue }
        $taskProject = [string](Value $task 'projectId' '')
        if ($ProjectId -and $taskProject -ne $ProjectId) { continue }
        $documents = @{}; $evidence = [Collections.Generic.List[string]]::new(); $fingerprints = [ordered]@{}
        foreach ($name in @('task','requirements-analysis','implementation-result','review-result','review-verification','task-summary','model-routing','provider-routing')) {
            $path = Join-Path $directory.FullName ($name + '.json')
            $documents[$name] = Read-Json $path
            if ($null -ne $documents[$name]) {
                $evidence.Add($name + '.json')
                $fingerprints[$name + '.json'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $streams = @{}
        foreach ($name in @('task-ledger','token-usage','role-metrics','workflow-routing')) {
            $path = Join-Path $directory.FullName ($name + '.jsonl'); $streams[$name] = $null
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try {
                    $streams[$name] = @(Read-Lines $path)
                    $evidence.Add($name + '.jsonl')
                    $fingerprints[$name + '.jsonl'] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                } catch { $streams[$name] = $null }
            }
        }
        $requirements = $documents['requirements-analysis']
        $taskPracticeVersion = [string](Value $requirements 'practiceVersion' '')
        $allRequirements = @(Value $requirements 'requirements' @())
        $ready = @($allRequirements | Where-Object { (Value $_ 'status') -in @('ready','already-satisfied') })
        $scenarios = @(Value $requirements 'verificationScenarios' @())
        $readyIds = @($ready | ForEach-Object { Value $_ 'acceptanceScenarioIds' @() } | Select-Object -Unique)
        $selectedScenarios = @($scenarios | Where-Object { (Value $_ 'id') -in $readyIds })
        $linked = @($allRequirements | Where-Object {
            $requirement = $_; $links = @(Value $requirement 'acceptanceScenarioIds' @())
            $valid = @($links | Where-Object {
                $link = $_
                @($scenarios | Where-Object { (Value $_ 'id') -eq $link -and (Value $requirement 'id') -in @(Value $_ 'requirementIds' @()) }).Count -eq 1
            })
            $links.Count -gt 0 -and $links.Count -eq $valid.Count
        })
        $review = $documents['review-result']; $verification = $documents['review-verification']; $implementation = $documents['implementation-result']
        $trustedReview = $false
        if ($review -and $verification) {
            $trustedReview = (Value $verification 'verificationStatus') -eq 'passed' -and
                (Value $verification 'reviewArtifactSha256') -ceq $fingerprints['review-result.json'] -and
                (Value $verification 'reviewedRevision') -eq (Value $review 'reviewedRevision')
            $reviewedCommit = ''
            if ([string](Value $review 'reviewedRevision') -match '^(?:git:)?([0-9a-fA-F]{40,64})(?:;|$)') { $reviewedCommit = $Matches[1] }
            $trustedReview = $trustedReview -and $reviewedCommit -and $reviewedCommit -eq (Value $implementation 'headCommit')
        }
        $verified = 0
        foreach ($scenario in $selectedScenarios) {
            $scenarioId = Value $scenario 'id'
            $implemented = @(Value $implementation 'scenarioResults' @() | Where-Object { (Value $_ 'scenarioId') -eq $scenarioId -and (Value $_ 'status') -eq 'passed' -and @(Value $_ 'evidence' @()).Count -gt 0 })
            $reviewed = @(Value $review 'requirementTraceability' @() | ForEach-Object { Value $_ 'scenarioResults' @() } | Where-Object { (Value $_ 'scenarioId') -eq $scenarioId })
            if ($trustedReview -and $implemented.Count -eq 1 -and $reviewed.Count -gt 0 -and
                @($reviewed | Where-Object {
                    (Value $_ 'verdict') -ne 'verified' -or -not @(Value $_ 'evidence' @()).Count -or
                    (Value $_ 'commit') -notmatch '^[a-fA-F0-9]{40,64}$' -or (Value $_ 'commit') -ne (Value $implemented[0] 'commit') -or
                    (Value $_ 'commit') -ne (Value $implementation 'headCommit')
                }).Count -eq 0) { $verified++ }
        }
        $routes = @($streams['workflow-routing'])
        $executionMode = if ($null -ne $streams['workflow-routing'] -and $routes.Count) { [string](Value $routes[-1] 'executionMode' '') } else { '' }
        $delivery = $executionMode -in @('full-delivery','local-poc-delivery','implementation-only')
        $complete = (Value $task 'status') -eq 'completed'; $duration = $null
        if ($complete -and $documents['task-summary']) {
            try {
                $start = [DateTimeOffset]::Parse([string](Value $task 'createdAtUtc'))
                $end = [DateTimeOffset]::Parse([string](Value $documents['task-summary'] 'completedAtUtc'))
                if ($end -ge $start) { $duration = [long]($end - $start).TotalMilliseconds }
            } catch { }
        }
        $ledger = $streams['task-ledger']; $tokens = @($streams['token-usage'])
        $usage = @($tokens | Where-Object {
            $count = 0L
            (Value $_ 'availability') -eq 'reported' -and [long]::TryParse([string](Value $_ 'totalTokens'),[ref]$count) -and $count -ge 0
        })
        $providers = @(Value $documents['provider-routing'] 'decisions' @())
        $modelDecisions = @(Value $documents['model-routing'] 'decisions' @())
        $modelParts = @($providers | ForEach-Object { '{0}={1}/{2}/{3}' -f (Value $_ 'agentId'),(Value $_ 'provider'),(Value $_ 'model'),(Value $_ 'reasoningEffort') } | Sort-Object -Unique)
        $actualParts = @($usage | ForEach-Object { '{0}={1}/{2}' -f (Value $_ 'agentId'),(Value $_ 'provider'),(Value $_ 'model') } | Sort-Object -Unique)
        $budgetParts = @($modelDecisions | ForEach-Object { '{0}={1}' -f (Value $_ 'agentId'),(Value $_ 'contextBudgetSignature') } | Sort-Object -Unique)
        $metadataComplete = $providers.Count -gt 0 -and $modelDecisions.Count -gt 0 -and $tokens.Count -gt 0 -and $usage.Count -eq $tokens.Count
        foreach ($decision in $providers) {
            foreach ($field in @('agentId','provider','model','reasoningEffort')) { if (-not (Value $decision $field)) { $metadataComplete = $false } }
            if (-not @($modelDecisions | Where-Object { (Value $_ 'agentId') -eq (Value $decision 'agentId') -and (Value $_ 'contextBudgetSignature') -match '^[a-f0-9]{64}$' }).Count) { $metadataComplete = $false }
        }
        foreach ($token in $usage) {
            if (-not @($providers | Where-Object { (Value $_ 'agentId') -eq (Value $token 'agentId') -and (Value $_ 'provider') -eq (Value $token 'provider') }).Count) { $metadataComplete = $false }
        }
        $attempts = @($streams['role-metrics'] | Where-Object { (Value $_ 'eventType') -eq 'role-attempt-completed' })
        $stageDurations = @($attempts | Group-Object agentId | ForEach-Object { [pscustomobject]@{agentId=$_.Name; attempts=$_.Count; durationMs=(Sum-Observed @($_.Group) 'durationMs')} })
        $artifactBytes = 0L
        foreach ($name in @('requirements-analysis.json','implementation-plan.json','review-result.json','idea-assessment.json')) {
            $path = Join-Path $directory.FullName $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { $artifactBytes += (Get-Item -LiteralPath $path).Length }
        }
        $contextPath = Join-Path $directory.FullName 'context-pack.json'
        $repositories = @(Value $task 'repositoryIds' @() | Sort-Object -Unique)
        $taskType = [string](Value $task 'taskType' '')
        $eligible = $taskPracticeVersion -eq $PracticeVersion -and $complete -and $delivery -and $metadataComplete -and $allRequirements.Count -gt 0 -and $selectedScenarios.Count -gt 0 -and
            $linked.Count -eq $allRequirements.Count -and $taskProject -and $repositories.Count -gt 0 -and $taskType -and $CohortLabel
        $taskEvaluations.Add([pscustomobject][ordered]@{
            taskId=[string](Value $task 'taskId' $directory.Name); projectId=$taskProject; status=[string](Value $task 'status' '')
            executionMode=$executionMode; taskType=$taskType; repositoryIds=$repositories
            practiceVersion=$taskPracticeVersion
            evaluationStatus=if($eligible){'evaluable'}else{'contract-metadata-missing'}
            criteriaTotal=if($requirements){$selectedScenarios.Count}else{$null}; criteriaVerified=if($requirements){$verified}else{$null}
            requirementCount=if($requirements){$allRequirements.Count}else{$null}; linkedRequirementCount=if($requirements){$linked.Count}else{$null}
            falseCompletion=if($complete -and $delivery){-not $requirements -or -not $selectedScenarios.Count -or $verified -lt $selectedScenarios.Count -or -not $documents['task-summary']}else{$null}
            humanInterventions=if($null -ne $ledger){Count-Events $ledger @('user-comment','question-resolved','review-decision','task-reopened','task-close-requested') 'user'}else{$null}
            clarifications=if($null -ne $ledger){Count-Events $ledger @('question-opened')}else{$null}
            failures=if($null -ne $ledger){Count-Events $ledger @('agent-failure')}else{$null}
            recoveries=if($null -ne $ledger){Count-Events $ledger @('agent-result') 'health_check'}else{$null}
            reviewReworkCount=if($null -ne $ledger){[Math]::Max(0,(Count-Events $ledger @('agent-result') 'reviewer') - 1)}else{$null}
            roleAttemptCount=if($null -ne $streams['role-metrics']){$attempts.Count}else{$null}; stageDurations=$stageDurations
            durationMs=$duration; totalTokens=if($usage.Count -eq $tokens.Count -and $tokens.Count){Sum-Observed $usage 'totalTokens'}else{$null}
            unavailableUsageRecords=if($null -ne $streams['token-usage']){$tokens.Count - $usage.Count}else{$null}
            artifactBytes=if($requirements){$artifactBytes}else{$null}; contextBytes=if(Test-Path -LiteralPath $contextPath -PathType Leaf){(Get-Item -LiteralPath $contextPath).Length}else{$null}
            modelSignature=($modelParts -join ';')+'|actual:'+($actualParts -join ';'); budgetSignature=($budgetParts -join ';'); evidence=@($evidence.ToArray()); sourceSha256=[pscustomobject]$fingerprints
        })
    }
}
$tasks = @($taskEvaluations.ToArray())
if ($TaskIds.Count) {
    $missing = @($TaskIds | Where-Object { $_ -notin @($tasks | ForEach-Object { $_.taskId }) })
    if ($missing.Count) { throw "Selected tasks missing, unreadable, or outside project: $($missing -join ', ')" }
}
$cohorts = @($tasks | Group-Object { @($_.projectId,($_.repositoryIds -join ','),$_.taskType,$_.executionMode,$_.modelSignature,$_.budgetSignature,$CohortLabel) -join '|' } | ForEach-Object {
    $members = @($_.Group)
    [pscustomobject][ordered]@{key=$_.Name; comparable=$members.Count -ge $MinimumCohortSize -and @($members | Where-Object evaluationStatus -ne 'evaluable').Count -eq 0; taskIds=@($members | ForEach-Object { $_.taskId }); metrics=(Metrics $members)}
})
$report = [pscustomobject][ordered]@{
    schemaVersion='2.0'; generatedAtUtc=[DateTime]::UtcNow.ToString('o'); projectId=if($ProjectId){$ProjectId}else{$null}
    collectorSha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    practiceVersion=$PracticeVersion; cohortLabel=$CohortLabel; skippedTaskDirectories=@($skipped.ToArray())
    comparisonPolicy=[pscustomobject]@{modelSignature='exact provider/model/reasoning per role'; budgetSignature='configured context limits'; minimumCohortSize=$MinimumCohortSize}
    summary=(Metrics $tasks); tasks=$tasks; cohorts=$cohorts
}
if ($OutputPath) {
    $resolved = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $resolved) { throw "Report already exists; choose a new snapshot path: $resolved" }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolved) -Force | Out-Null
    Write-Utf8NoBom -Path $resolved -Content (($report | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}
$report
