[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $CompletedAgentId,
    [switch] $ElevatedApproved,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$knownAgentIds = @($config.agents | ForEach-Object { [string]$_.id })
if ($CompletedAgentId -notin $knownAgentIds) { throw "Unknown completed agent '$CompletedAgentId'." }
$chainConfig = $config.workflow.automaticContinuation
if (-not [bool]$chainConfig.enabled) { return [pscustomobject]@{ Status='disabled'; StartedAgents=@() } }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$continuationLockPath = Join-Path $taskRoot 'automatic-continuation.lock'
try {
    $continuationLock = [IO.File]::Open($continuationLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch [IO.IOException] {
    return [pscustomobject]@{ Status='busy'; Reason='Another trusted host owns automatic continuation for this task.'; StartedAgents=@() }
}

try {
$started = [Collections.Generic.List[string]]::new()
$currentAgentId = $CompletedAgentId
$transitionCounts = @{}

function Stop-AutomaticChain {
    param([Parameter(Mandatory)][string] $Reason)

    $failure = & (Join-Path $PSScriptRoot 'Write-AgentFailure.ps1') -TaskId $TaskId -AgentId orchestrator -Stage automatic_chain_guard -Summary $Reason -Diagnostic $Reason -Evidence @($taskPath) -ConfigPath $ConfigPath -CodexHome $CodexHome
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId orchestrator -AgentStatus failed -Stage automatic_chain_guard -Message $Reason -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status failed -Stage automatic_chain_guard -Message $Reason -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $recovery = $null
    try {
        $recoveryParameters = @{ TaskId = $TaskId; FailurePath = [string]$failure.FailurePath; ConfigPath = $ConfigPath; CodexHome = $CodexHome }
        if ($ElevatedApproved) { $recoveryParameters.ElevatedApproved = $true }
        $recovery = & (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') @recoveryParameters
    }
    catch {
        Write-Warning ('Automatic chain failure was persisted, but Health Check launch failed: ' + $_.Exception.Message)
    }
    return [pscustomobject]@{ Status = 'failed'; Reason = $Reason; FailurePath = [string]$failure.FailurePath; HealthRecovery = $recovery; StartedAgents = @($started) }
}

function Get-LatestDecisions {
    $result = @{}
    $path = Join-Path $taskRoot 'review-decisions.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
    $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in @($document.decisions)) { $result[[string]$entry.findingId] = [string]$entry.decision }
    return $result
}

function Add-ApprovedFindingInput {
    param(
        [Parameter(Mandatory)][string] $FindingId,
        [Parameter(Mandatory)][string] $FindingSummary,
        [Parameter(Mandatory)][ValidateSet('developer','orchestrator')][string] $TargetAgentId,
        [Parameter(Mandatory)][string] $ReviewPath
    )

    $evidenceKey = 'review-finding:' + $FindingId
    $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $event = $line | ConvertFrom-Json } catch { continue }
            if ([string]$event.type -eq 'workflow-input-routed' -and [string]$event.targetAgentId -eq $TargetAgentId -and @($event.evidence) -contains $evidenceKey -and @($event.evidence) -contains 'decision:approved' -and ([string]$event.summary).Contains($FindingSummary)) { return $event }
        }
    }
    $summary = 'Human-approved Reviewer finding ' + $FindingId + ': ' + $FindingSummary + ' The approval is already recorded; do not reopen the approval gate.'
    return (& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor reviewer -Type workflow-input-routed -Summary $summary -Artifact (Join-Path $taskRoot 'review-decisions.json') -Evidence @($evidenceKey, 'decision:approved', $ReviewPath, (Join-Path $taskRoot 'review-decisions.json')) -TargetAgentId $TargetAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome)
}

function Get-FindingRoutingSummary {
    param([Parameter(Mandatory)] $Finding)

    foreach ($propertyName in @('correctionDirection','suggestedCorrection','summary','impact','evidence')) {
        if ($Finding.PSObject.Properties[$propertyName] -and -not [string]::IsNullOrWhiteSpace([string]$Finding.$propertyName)) {
            return [string]$Finding.$propertyName
        }
    }
    [string]$Finding.id
}

function Get-ActiveExecutionPolicy {
    $defaultMode = $config.workflow.orchestration.executionModes.'full-delivery'
    $result = [ordered]@{
        ExecutionMode = 'full-delivery'
        AgentSequence = @($defaultMode.agentSequence | ForEach-Object { [string]$_ })
        CodeChangesAllowed = [bool]$defaultMode.codeChangesAllowed
        ContinueAutomatically = [bool]$defaultMode.continueAutomatically
    }
    $routingPath = Join-Path $taskRoot ([string]$config.workflow.orchestration.routingArtifact)
    if (-not (Test-Path -LiteralPath $routingPath -PathType Leaf)) { return [pscustomobject]$result }
    $routes = @(Get-Content -LiteralPath $routingPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
    $latest = @($routes | Where-Object { $_.PSObject.Properties['executionMode'] -and $_.PSObject.Properties['agentSequence'] }) | Select-Object -Last 1
    if (-not $latest) { return [pscustomobject]$result }
    $result.ExecutionMode = [string]$latest.executionMode
    $result.AgentSequence = @($latest.agentSequence | ForEach-Object { [string]$_ })
    $result.CodeChangesAllowed = [bool]$latest.codeChangesAllowed
    $result.ContinueAutomatically = [bool]$latest.continueAutomatically
    return [pscustomobject]$result
}

function Get-NextPolicyAgent {
    param(
        [Parameter(Mandatory)][string] $AgentId,
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] $ExecutionPolicy
    )
    if (-not [bool]$ExecutionPolicy.ContinueAutomatically) { return $null }
    $sequence = @($ExecutionPolicy.AgentSequence)
    $currentIndex = [Array]::IndexOf($sequence, $AgentId)
    if ($currentIndex -lt 0) { return $null }
    $nextIndex = $currentIndex + 1
    if ($nextIndex -ge $sequence.Count) { return $null }
    return [string]$sequence[$nextIndex]
}

for ($step = 1; $step -le [int]$chainConfig.maxChainSteps; $step++) {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $executionPolicy = Get-ActiveExecutionPolicy
    $agentSequence = @($executionPolicy.AgentSequence)
    $currentAgentStatus = [string]$task.agentStatuses.$currentAgentId.status
    if ($currentAgentStatus -ne 'completed') {
        if ($currentAgentStatus -eq 'waiting') { return [pscustomobject]@{ Status='waiting'; Reason=('Agent ' + $currentAgentId + ' reached an explicit input or approval gate.'); StartedAgents=@($started) } }
        if ($currentAgentStatus -eq 'failed') { return [pscustomobject]@{ Status='failed'; Reason=('Agent ' + $currentAgentId + ' failed and handed evidence to Health Check.'); StartedAgents=@($started) } }
        return [pscustomobject]@{ Status='stopped'; Reason=('Agent ' + $currentAgentId + ' ended with non-continuable status ' + $currentAgentStatus + '.'); StartedAgents=@($started) }
    }

    $nextAgentId = $null
    $authorityHandoffPending = $false
    if ($currentAgentId -ne 'orchestrator' -and [bool]$config.workflow.orchestration.forwardOutOfScopeComments -and [bool]$config.workflow.orchestration.autoDispatchForwardedComments) {
        $orchestratorBatch = & (Join-Path $PSScriptRoot 'Get-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome
        $authorityHandoffPending = @($orchestratorBatch.comments | Where-Object { [string]$_.eventType -in @('agent-routing-request','workflow-input-routed') }).Count -gt 0
        if ($authorityHandoffPending) { $nextAgentId = 'orchestrator' }
    }
    # A successful Developer outcome intentionally leaves the task in
    # review_pending. That gate means run Reviewer next, not wait for a human
    # decision; human review decisions are evaluated after Reviewer findings.
    $reevaluateDeveloperGate = $currentAgentId -eq 'developer' -and [string]$task.status -eq 'review_pending'
    $reevaluateReviewerGate = $currentAgentId -eq 'reviewer' -and [string]$task.status -eq 'review_pending'
    $reevaluatePipelineGate = $currentAgentId -eq 'pipeline_monitor' -and [string]$task.status -in @('waiting_for_input','held')
    $reevaluateOrchestratorGate = $currentAgentId -eq 'orchestrator'
    if (-not $authorityHandoffPending -and [string]$task.status -in @($chainConfig.stopStatuses) -and -not $reevaluateDeveloperGate -and -not $reevaluateReviewerGate -and -not $reevaluatePipelineGate -and -not $reevaluateOrchestratorGate) {
        return [pscustomobject]@{ Status='waiting'; Reason="Task gate '$([string]$task.status)' is active."; StartedAgents=@($started) }
    }
    if (-not $authorityHandoffPending -and ($currentAgentId -eq 'orchestrator' -or [bool]$executionPolicy.ContinueAutomatically)) {
    switch ($currentAgentId) {
        'orchestrator' {
            foreach ($candidate in @($config.workflow.orchestration.dispatchPriority)) {
                if ([string]$candidate -notin $agentSequence) { continue }
                $pendingInput = & (Join-Path $PSScriptRoot 'Get-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId ([string]$candidate) -ConfigPath $ConfigPath -CodexHome $CodexHome
                if ([int]$pendingInput.count -gt 0) { $nextAgentId = [string]$candidate; break }
            }
            if (-not $nextAgentId -and [bool]$executionPolicy.ContinueAutomatically -and [string]$task.status -notin @($chainConfig.stopStatuses)) {
                foreach ($candidate in $agentSequence) {
                    if ([string]$candidate -in @('orchestrator','health_check')) { continue }
                    $candidateStatus = if ($task.agentStatuses.PSObject.Properties[[string]$candidate]) { [string]$task.agentStatuses.([string]$candidate).status } else { 'pending' }
                    if ($candidateStatus -in @('pending','skipped')) { $nextAgentId = [string]$candidate; break }
                }
            }
        }
        'requirements_analyst' { $nextAgentId = Get-NextPolicyAgent -AgentId $currentAgentId -Task $task -ExecutionPolicy $executionPolicy }
        'developer' { $nextAgentId = Get-NextPolicyAgent -AgentId $currentAgentId -Task $task -ExecutionPolicy $executionPolicy }
        'reviewer' {
            $reviewPath = Join-Path $taskRoot 'review-result.json'
            if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw 'Reviewer completed without review-result.json.' }
            $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $productFindings = @($review.findings)
            $processFindings = @($review.agentProcessFindings)
            $decisions = Get-LatestDecisions
            $techDebtPath = Join-Path $taskRoot 'tech-debt-items.json'
            $techDebtItems = if (Test-Path -LiteralPath $techDebtPath -PathType Leaf) { @((Get-Content -LiteralPath $techDebtPath -Raw -Encoding UTF8 | ConvertFrom-Json).items) } else { @() }
            $approvedProcess = @($processFindings | Where-Object { $decisions[[string]$_.id] -eq 'approved' })
            foreach ($finding in $approvedProcess) {
                $findingSummary = Get-FindingRoutingSummary -Finding $finding
                $null = Add-ApprovedFindingInput -FindingId ([string]$finding.id) -FindingSummary $findingSummary -TargetAgentId orchestrator -ReviewPath $reviewPath
            }
            if ($productFindings.Count) {
                $undecided = @($productFindings | Where-Object { -not $decisions.ContainsKey([string]$_.id) })
                $deferred = @($productFindings | Where-Object { $decisions[[string]$_.id] -eq 'deferred' })
                $invalidBypasses = @($productFindings | Where-Object {
                    $findingId = [string]$_.id
                    $decisions[$findingId] -eq 'bypassed' -and -not @($techDebtItems | Where-Object { [string]$_.sourceFindingId -eq $findingId -and [string]$_.status -eq 'open' }).Count
                })
                $blocked = @($undecided) + @($deferred) + @($invalidBypasses)
                if ($blocked.Count) {
                    $message = "Reviewer produced $($blocked.Count) product finding(s) that are undecided, deferred, or missing an open bypass tech-debt item."
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status review_pending -Stage review_decision_required -Message $message -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    return [pscustomobject]@{ Status='review-pending'; Reason=$message; StartedAgents=@($started) }
                }
                $approvedProduct = @($productFindings | Where-Object { $decisions[[string]$_.id] -eq 'approved' })
                if ($approvedProduct.Count) {
                    foreach ($finding in $approvedProduct) {
                        $findingSummary = Get-FindingRoutingSummary -Finding $finding
                        $null = Add-ApprovedFindingInput -FindingId ([string]$finding.id) -FindingSummary $findingSummary -TargetAgentId developer -ReviewPath $reviewPath
                    }
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId developer -AgentStatus pending -Stage approved_review_rework -Message 'Approved Reviewer findings require Developer rework.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId reviewer -AgentStatus pending -Stage review_after_rework -Message 'Reviewer must validate the approved rework.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    if ('developer' -notin $agentSequence -or -not [bool]$executionPolicy.CodeChangesAllowed) {
                        return [pscustomobject]@{ Status='review-pending'; Reason="Approved findings require Developer, but execution mode '$([string]$executionPolicy.ExecutionMode)' forbids that continuation."; StartedAgents=@($started) }
                    }
                    $nextAgentId = 'developer'
                }
                else { $nextAgentId = Get-NextPolicyAgent -AgentId $currentAgentId -Task $task -ExecutionPolicy $executionPolicy }
            }
            else { $nextAgentId = Get-NextPolicyAgent -AgentId $currentAgentId -Task $task -ExecutionPolicy $executionPolicy }
        }
        'pipeline_monitor' {
            $pipelinePath = Join-Path $taskRoot 'pipeline-result.json'
            if (-not (Test-Path -LiteralPath $pipelinePath -PathType Leaf)) {
                return [pscustomobject]@{ Status='waiting'; Reason='Pipeline Monitor completed without an exact-commit pipeline result.'; StartedAgents=@($started) }
            }
            $pipeline = Get-Content -LiteralPath $pipelinePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$pipeline.overallResult -eq 'succeeded') {
                $prPath = Join-Path $taskRoot 'pull-request-status.json'
                if (-not (Test-Path -LiteralPath $prPath -PathType Leaf)) { return [pscustomobject]@{ Status='waiting'; Reason='Build succeeded; waiting for the first task PR status synchronization.'; StartedAgents=@($started) } }
                $prStatus = [string](Get-Content -LiteralPath $prPath -Raw -Encoding UTF8 | ConvertFrom-Json).status
                if ($prStatus -in @($config.pipeline.pullRequests.completedStatuses)) { $nextAgentId = 'orchestrator' }
                elseif ($prStatus -in @($config.pipeline.pullRequests.abandonedStatuses)) { return [pscustomobject]@{ Status='waiting'; Reason='The task PR was abandoned and requires human input.'; StartedAgents=@($started) } }
                else { return [pscustomobject]@{ Status='waiting'; Reason="Build succeeded; PR status is '$prStatus'."; StartedAgents=@($started) } }
            }
            elseif ($pipeline.PSObject.Properties['remediation'] -and [string]$pipeline.remediation.targetAgentId -eq 'developer' -and [string]$pipeline.remediation.status -eq 'pending') {
                & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId reviewer -AgentStatus pending -Stage review_after_pipeline_fix -Message 'Reviewer must validate the pipeline remediation.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId pipeline_monitor -AgentStatus pending -Stage pipeline_after_remediation_review -Message 'Pipeline Monitor must validate the remediated exact commit after reviewed delivery.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                $nextAgentId = 'developer'
            }
            else {
                $failureSignature = if ($pipeline.PSObject.Properties['remediation']) { [string]$pipeline.remediation.failureSignature } else { '' }
                $evidenceKey = if ([string]::IsNullOrWhiteSpace($failureSignature)) { "pipeline-result:$([string]$pipeline.overallResult)" } else { "pipeline-failure-signature:$failureSignature" }
                $existingHandoff = $false
                $ledgerPath = Join-Path $taskRoot 'task-ledger.jsonl'
                if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                    foreach ($line in @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8)) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        try { $event = $line | ConvertFrom-Json } catch { continue }
                        if ([string]$event.type -eq 'agent-routing-request' -and [string]$event.targetAgentId -eq 'orchestrator' -and @($event.evidence) -contains $evidenceKey) {
                            $existingHandoff = $true
                            break
                        }
                    }
                }
                if ($existingHandoff) {
                    return [pscustomobject]@{ Status='waiting'; Reason="Pipeline result '$([string]$pipeline.overallResult)' already has an Orchestrator handoff."; StartedAgents=@($started) }
                }
                $reason = "Pipeline result '$([string]$pipeline.overallResult)' was not eligible for deterministic Developer remediation. Orchestrator must assign the remaining infrastructure, credential, Health Check, or human-input decision without asking the user to restart an agent."
                & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type agent-routing-request -Summary $reason -Artifact $pipelinePath -Evidence @($evidenceKey, $pipelinePath) -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -AgentId orchestrator -AgentStatus pending -Stage pipeline_authority_handoff -Message $reason -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                $nextAgentId = 'orchestrator'
            }
        }
        'health_check' {
            foreach ($candidate in $agentSequence) {
                if ([string]$candidate -in @('orchestrator','health_check')) { continue }
                $candidateStatus = if ($task.agentStatuses.PSObject.Properties[[string]$candidate]) { [string]$task.agentStatuses.([string]$candidate).status } else { 'pending' }
                if ($candidateStatus -in @('pending','skipped')) {
                    $nextAgentId = [string]$candidate
                    break
                }
            }
        }
        'knowledge_keeper' {
            foreach ($candidate in $agentSequence) {
                if ($candidate -eq 'knowledge_keeper') { continue }
                if ([string]$task.agentStatuses.$candidate.status -ne 'completed') { $nextAgentId = $candidate; break }
            }
        }
    }
    }
    if (-not $nextAgentId) { return [pscustomobject]@{ Status='completed'; StartedAgents=@($started) } }
    $transitionKey = $currentAgentId + '->' + $nextAgentId
    $transitionCounts[$transitionKey] = if ($transitionCounts.ContainsKey($transitionKey)) { [int]$transitionCounts[$transitionKey] + 1 } else { 1 }
    if ([int]$transitionCounts[$transitionKey] -gt [int]$chainConfig.maxTransitionRepeats) {
        return (Stop-AutomaticChain -Reason ('Automatic continuation stopped before transition ' + $transitionKey + ' because its maximum of ' + [int]$chainConfig.maxTransitionRepeats + ' repetitions was reached.'))
    }
    if ($PrepareOnly) {
        return [pscustomobject]@{ Status='prepared'; NextAgentId=$nextAgentId; StartedAgents=@($started) }
    }

    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor ecosystem -Type workflow-status -Summary "Automatic chain continuation scheduled '$nextAgentId' after '$currentAgentId'." -TargetAgentId $nextAgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    $repositoryIds = if ($task.PSObject.Properties['repositoryIds']) { @($task.repositoryIds) } elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) { @([string]$task.repositoryId) } else { @() }
    if (-not @($repositoryIds).Count) { throw "Task '$TaskId' has no repository scope for automatic continuation." }
    $workflowParameters = @{
        Mode=[string]$task.mode; TaskSelector=[string]$task.selector; TaskId=$TaskId
        RepositoryIds=@($repositoryIds); UserInstruction="Automatic continuation after '$currentAgentId'. Run only '$nextAgentId' and stop at every human-input or approval gate."
        Resume=$true; TargetAgentId=$nextAgentId; SkipChainContinuation=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
    }
    if ($ElevatedApproved -or [bool]$chainConfig.useElevatedExecution) { $workflowParameters.ElevatedApproved = $true }
    $started.Add($nextAgentId)
    & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @workflowParameters | Out-Null
    $currentAgentId = $nextAgentId
}

Stop-AutomaticChain -Reason ('Automatic continuation reached its configured limit of ' + [int]$chainConfig.maxChainSteps + ' steps before reaching a terminal gate.')
}
finally {
    $continuationLock.Dispose()
}
