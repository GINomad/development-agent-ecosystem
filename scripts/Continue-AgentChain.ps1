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
$started = [Collections.Generic.List[string]]::new()
$currentAgentId = $CompletedAgentId

function Get-LatestDecisions {
    $result = @{}
    $path = Join-Path $taskRoot 'review-decisions.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
    $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in @($document.decisions)) { $result[[string]$entry.findingId] = [string]$entry.decision }
    return $result
}

for ($step = 1; $step -le [int]$chainConfig.maxChainSteps; $step++) {
    $task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $reevaluateReviewerGate = $currentAgentId -eq 'reviewer' -and [string]$task.status -eq 'review_pending'
    if ([string]$task.status -in @($chainConfig.stopStatuses) -and -not $reevaluateReviewerGate) {
        return [pscustomobject]@{ Status='waiting'; Reason="Task gate '$([string]$task.status)' is active."; StartedAgents=@($started) }
    }
    if ([string]$task.agentStatuses.$currentAgentId.status -ne 'completed') {
        return [pscustomobject]@{ Status='stopped'; Reason="Agent '$currentAgentId' did not complete successfully."; StartedAgents=@($started) }
    }

    $nextAgentId = $null
    switch ($currentAgentId) {
        'orchestrator' {
            foreach ($candidate in @($config.workflow.orchestration.dispatchPriority)) {
                $pendingInput = & (Join-Path $PSScriptRoot 'Get-AgentCommentBatch.ps1') -TaskId $TaskId -AgentId ([string]$candidate) -ConfigPath $ConfigPath -CodexHome $CodexHome
                if ([int]$pendingInput.count -gt 0) { $nextAgentId = [string]$candidate; break }
            }
        }
        'requirements_analyst' { $nextAgentId = 'developer' }
        'developer' { $nextAgentId = 'reviewer' }
        'reviewer' {
            $reviewPath = Join-Path $taskRoot 'review-result.json'
            if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw 'Reviewer completed without review-result.json.' }
            $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $productFindings = @($review.findings)
            if ($productFindings.Count) {
                $decisions = Get-LatestDecisions
                $undecided = @($productFindings | Where-Object { -not $decisions.ContainsKey([string]$_.id) })
                if ($undecided.Count) {
                    $message = "Reviewer produced $($undecided.Count) product finding(s) that require a human decision."
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status review_pending -Stage review_decision_required -Message $message -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    return [pscustomobject]@{ Status='review-pending'; Reason=$message; StartedAgents=@($started) }
                }
                $approvedProduct = @($productFindings | Where-Object { $decisions[[string]$_.id] -eq 'approved' })
                if ($approvedProduct.Count) {
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId developer -AgentStatus pending -Stage approved_review_rework -Message 'Approved Reviewer findings require Developer rework.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId reviewer -AgentStatus pending -Stage review_after_rework -Message 'Reviewer must validate the approved rework.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    $nextAgentId = 'developer'
                }
                else { $nextAgentId = 'pipeline_monitor' }
            }
            else { $nextAgentId = 'pipeline_monitor' }
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
                if ($prStatus -in @($config.pipeline.pullRequests.completedStatuses)) { $nextAgentId = 'knowledge_keeper' }
                elseif ($prStatus -in @($config.pipeline.pullRequests.abandonedStatuses)) { return [pscustomobject]@{ Status='waiting'; Reason='The task PR was abandoned and requires human input.'; StartedAgents=@($started) } }
                else { return [pscustomobject]@{ Status='waiting'; Reason="Build succeeded; PR status is '$prStatus'."; StartedAgents=@($started) } }
            }
            elseif ($pipeline.PSObject.Properties['remediation'] -and [string]$pipeline.remediation.targetAgentId -eq 'developer' -and [string]$pipeline.remediation.status -eq 'pending') {
                & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId reviewer -AgentStatus pending -Stage review_after_pipeline_fix -Message 'Reviewer must validate the pipeline remediation.' -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                $nextAgentId = 'developer'
            }
            else { return [pscustomobject]@{ Status='waiting'; Reason="Pipeline result '$([string]$pipeline.overallResult)' requires human or infrastructure intervention."; StartedAgents=@($started) } }
        }
        'knowledge_keeper' {
            foreach ($candidate in @('requirements_analyst','developer','reviewer','pipeline_monitor')) {
                if ([string]$task.agentStatuses.$candidate.status -ne 'completed') { $nextAgentId = $candidate; break }
            }
        }
    }
    if (-not $nextAgentId) { return [pscustomobject]@{ Status='completed'; StartedAgents=@($started) } }
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

[pscustomobject]@{ Status='step-limit'; Reason='Automatic continuation reached its configured step limit.'; StartedAgents=@($started) }
