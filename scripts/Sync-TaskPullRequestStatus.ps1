[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $RepositoryId,
    [string] $PullRequestsJsonPath,
    [switch] $DoNotStartKnowledgeUpdate,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function ConvertTo-PullRequestList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [array]) { return @($Value.GetEnumerator()) }
    return @($Value)
}

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.pipeline.pullRequests.enabled) { return [pscustomobject]@{ Status='disabled'; TaskId=$TaskId } }
$repository = @($config.repositories | Where-Object { [string]$_.id -eq $RepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
if (-not $repository -or [string]$repository.provider -ne 'azure-devops') { throw "Enabled Azure repository '$RepositoryId' was not found." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($task.PSObject.Properties['closure'] -and [string]$task.closure.status -in @('knowledge-update-pending','completed')) { return [pscustomobject]@{ Status=[string]$task.closure.status; TaskId=$TaskId } }

$deliveryPath = Join-Path $taskRoot 'delivery-result.json'
$pipelinePath = Join-Path $taskRoot 'pipeline-result.json'
$branch = $null
if (Test-Path -LiteralPath $deliveryPath -PathType Leaf) { $branch = [string](Get-Content -LiteralPath $deliveryPath -Raw -Encoding UTF8 | ConvertFrom-Json).branch }
elseif (Test-Path -LiteralPath $pipelinePath -PathType Leaf) { $branch = [string](Get-Content -LiteralPath $pipelinePath -Raw -Encoding UTF8 | ConvertFrom-Json).branch }
if ([string]::IsNullOrWhiteSpace($branch)) { throw 'A delivered working branch is required before PR synchronization.' }
$sourceRef = 'refs/heads/' + ($branch -replace '^refs/heads/','')

if ($PullRequestsJsonPath) {
    $parsedPullRequests = Get-Content -LiteralPath $PullRequestsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pullRequests = @(ConvertTo-PullRequestList -Value $parsedPullRequests)
}
else {
    $credential = @($config.credentialProfiles | Where-Object { [string]$_.id -eq [string]$repository.credentialProfile }) | Select-Object -First 1
    $azPath = [string]$credential.cliPath
    if (-not (Test-Path -LiteralPath $azPath -PathType Leaf)) { throw "Azure CLI was not found: $azPath" }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $json = @(& $azPath repos pr list --organization ([string]$repository.organizationUrl) --project ([string]$repository.project) --repository ([string]$repository.repository) --source-branch $sourceRef --status all --top 25 --output json 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exitCode -ne 0) { throw "Azure PR query failed with exit code $exitCode. $(@($json | Select-Object -Last 8) -join ' ')" }
    $parsedPullRequests = ($json -join [Environment]::NewLine) | ConvertFrom-Json
    $pullRequests = @(ConvertTo-PullRequestList -Value $parsedPullRequests)
}
$matching = @($pullRequests | Where-Object {
    $sourceProperty = $_.PSObject.Properties['sourceRefName']
    $sourceProperty -and [string]$sourceProperty.Value -eq $sourceRef
} | Sort-Object {
    $creationProperty = $_.PSObject.Properties['creationDate']
    if ($creationProperty -and $creationProperty.Value) { [datetime]::Parse([string]$creationProperty.Value) } else { [datetime]::MinValue }
} -Descending)
$pr = $matching | Select-Object -First 1
$status = if ($pr) { ([string]$pr.status).ToLowerInvariant() } else { 'not-created' }
$result = [ordered]@{
    taskId=$TaskId; repositoryId=$RepositoryId; branch=$branch; sourceRefName=$sourceRef; status=$status
    pullRequestId=if ($pr) { [int]$pr.pullRequestId } else { $null }
    title=if ($pr) { [string]$pr.title } else { $null }
    url=if ($pr -and $pr.PSObject.Properties['url']) { [string]$pr.url } else { $null }
    createdBy=if ($pr -and $pr.PSObject.Properties['createdBy']) { [string]$pr.createdBy.displayName } else { $null }
    syncedAtUtc=[DateTime]::UtcNow.ToString('o')
}
$resultPath = Join-Path $taskRoot 'pull-request-status.json'
$previousStatus = $null
if (Test-Path -LiteralPath $resultPath -PathType Leaf) { try { $previousStatus = [string](Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json).status } catch {} }
Write-Utf8NoBom -Path $resultPath -Content (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
if ($previousStatus -ne $status) {
    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type pr-status -Summary "Pull request status for '$branch' changed to '$status'." -Artifact $resultPath -Evidence @("pr:$($result.pullRequestId)") -TargetAgentId orchestrator -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
}

if ($status -in @($config.pipeline.pullRequests.completedStatuses)) {
    $reason = "Azure pull request $($result.pullRequestId) completed for $branch."
    $closure = & (Join-Path $PSScriptRoot 'Request-TaskClosure.ps1') -TaskId $TaskId -Reason $reason -Kind pr-completed -ConfigPath $ConfigPath -CodexHome $CodexHome
    if (-not $DoNotStartKnowledgeUpdate) {
        $workflowParameters = @{
            Mode=[string]$task.mode; TaskSelector=[string]$task.selector; TaskId=$TaskId; RepositoryIds=@($task.repositoryIds)
            UserInstruction='The task PR completed. Run only Orchestrator to validate the terminal evidence and route the final publication command to Knowledge Keeper.'
            Resume=$true; TargetAgentId='orchestrator'; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
        }
        & (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') @workflowParameters | Out-Null
    }
    return [pscustomobject]@{ Status='completion-requested'; Result=[pscustomobject]$result; Closure=$closure; ResultPath=$resultPath }
}
if ($status -in @($config.pipeline.pullRequests.abandonedStatuses)) {
    & (Join-Path $PSScriptRoot 'Open-AgentQuestion.ps1') -TaskId $TaskId -AgentId pipeline_monitor -Question "Pull request $($result.pullRequestId) for '$branch' was abandoned. Reopen the task, provide a replacement PR, or confirm manual closure." -Evidence @($resultPath) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
    return [pscustomobject]@{ Status='waiting-for-input'; Result=[pscustomobject]$result; ResultPath=$resultPath }
}
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status interrupted -Stage awaiting_pull_request -Message "Build succeeded; waiting for the task PR on '$branch' to complete." -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
[pscustomobject]@{ Status='waiting'; Result=[pscustomobject]$result; ResultPath=$resultPath }
