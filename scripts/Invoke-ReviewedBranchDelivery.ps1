[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $RepositoryId,
    [ValidateRange(0,3)][int] $RemediationCycle = 0,
    [switch] $PrepareOnly,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not [bool]$config.pipeline.delivery.autoPushAfterCleanReview) { throw 'Automatic reviewed-branch delivery is disabled.' }
$repository = @($config.repositories | Where-Object { [string]$_.id -eq $RepositoryId -and [bool]$_.enabled }) | Select-Object -First 1
if (-not $repository -or [string]$repository.provider -ne 'azure-devops') { throw "Enabled Azure repository '$RepositoryId' was not found." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
$taskPath = Join-Path $taskRoot 'task.json'
$reviewPath = Join-Path $taskRoot 'review-result.json'
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf) -or -not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw 'Task and review-result.json are required before delivery.' }
$task = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskRepositoryIds = @(if ($task.PSObject.Properties['repositoryIds']) {
    @($task.repositoryIds | ForEach-Object { [string]$_ })
}
elseif ($task.PSObject.Properties['repositoryId'] -and $task.repositoryId) {
    @([string]$task.repositoryId)
}
else { @() })
if (-not $taskRepositoryIds.Count) { throw "Task '$TaskId' does not persist a repository scope." }
if ($RepositoryId -notin $taskRepositoryIds) { throw "Repository '$RepositoryId' is outside the task scope." }
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
$productFindings = @($review.findings)
$decisionsPath = Join-Path $taskRoot 'review-decisions.json'
$debtPath = Join-Path $taskRoot 'tech-debt-items.json'
$latestDecisions = @{}
if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) {
    foreach ($entry in @((Get-Content -LiteralPath $decisionsPath -Raw -Encoding UTF8 | ConvertFrom-Json).decisions)) { $latestDecisions[[string]$entry.findingId] = $entry }
}
$techDebtItems = if (Test-Path -LiteralPath $debtPath -PathType Leaf) { @((Get-Content -LiteralPath $debtPath -Raw -Encoding UTF8 | ConvertFrom-Json).items) } else { @() }
$blockingFindingIds = [Collections.Generic.List[string]]::new()
foreach ($finding in $productFindings) {
    $findingId = [string]$finding.id
    $decision = if ($latestDecisions.ContainsKey($findingId)) { [string]$latestDecisions[$findingId].decision } else { '' }
    $validBypass = $decision -eq 'bypassed' -and @($techDebtItems | Where-Object { [string]$_.sourceFindingId -eq $findingId -and [string]$_.status -eq 'open' }).Count -gt 0
    if ($decision -eq 'rejected' -or $validBypass) { continue }
    $blockingFindingIds.Add($findingId)
}
if ($blockingFindingIds.Count) { throw "Product review findings block delivery: $($blockingFindingIds -join ', '). Approved findings require a fresh review; deferred or undecided findings require a human decision; bypassed findings require an open linked tech-debt item." }
if (@($review.heldScopeViolations).Count -gt 0) { throw 'Held-scope violations block delivery.' }
if ([string]$task.agentStatuses.reviewer.status -ne 'completed') { throw 'Reviewer has not published a successful outcome.' }

$resolvedWorkspace = & (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -RepositoryId $RepositoryId -ConfigPath $ConfigPath -CodexHome $CodexHome
$workspace = [IO.Path]::GetFullPath([string]$resolvedWorkspace.Path)
if (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) { throw "Git workspace was not found: $workspace" }
function Invoke-Git {
    param([string[]] $Arguments, [int[]] $AllowedExitCodes = @(0))
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $workspace @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -notin $AllowedExitCodes) { throw "git $($Arguments -join ' ') failed with exit code $code. $(@($output | Select-Object -Last 8) -join ' ')" }
    return @($output)
}

$branch = [string](Invoke-Git @('branch','--show-current') | Select-Object -First 1)
$commit = [string](Invoke-Git @('rev-parse','HEAD') | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($branch) -or $branch -in @($config.pipeline.delivery.forbiddenBranches)) { throw "Delivery is forbidden from branch '$branch'." }
if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Could not resolve the full local commit SHA.' }
$statusLines = @(Invoke-Git @('status','--porcelain=v1','--untracked-files=all'))
if ([bool]$config.pipeline.delivery.requireCleanWorktree -and @($statusLines | Where-Object { $_ }).Count) { throw 'The worktree is not clean. Developer must commit the reviewed changes before automatic delivery.' }
$remoteUrl = [string](Invoke-Git @('remote','get-url',[string]$config.pipeline.delivery.remote) | Select-Object -First 1)
if ($remoteUrl -notmatch [regex]::Escape([string]$repository.repository)) { throw 'The configured origin does not match the task repository.' }

$plan = [pscustomobject][ordered]@{
    taskId=$TaskId; repositoryId=$RepositoryId; workspace=$workspace; remote='origin'; remoteUrl=$remoteUrl
    branch=$branch; commit=$commit.ToLowerInvariant(); pushRef="HEAD:refs/heads/$branch"; force=$false; tags=$false
    reviewPath=$reviewPath; reviewDecisionsPath=if (Test-Path -LiteralPath $decisionsPath) { $decisionsPath } else { $null }
    techDebtItemsPath=if (Test-Path -LiteralPath $debtPath) { $debtPath } else { $null }
    preparedAtUtc=[DateTime]::UtcNow.ToString('o')
}
if ($PrepareOnly -or -not $PSCmdlet.ShouldProcess("origin/$branch", "push reviewed commit $commit and monitor its build")) { return $plan }

$queuedAfter = [DateTime]::UtcNow
$pushOutput = @(Invoke-Git @('push','origin',"HEAD:refs/heads/$branch"))
$deliveryPath = Join-Path $taskRoot 'delivery-result.json'
$delivery = [ordered]@{ taskId=$TaskId; repositoryId=$RepositoryId; branch=$branch; commit=$commit.ToLowerInvariant(); remote='origin'; pushedAtUtc=[DateTime]::UtcNow.ToString('o'); pushOutputTail=@($pushOutput | Select-Object -Last 20); force=$false; tags=$false }
Write-Utf8NoBom -Path $deliveryPath -Content (($delivery | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor pipeline_monitor -Type external-action -Summary "Pushed reviewed commit $($commit.Substring(0,12)) to origin/$branch without force or tags." -Artifact $deliveryPath -Evidence @($reviewPath, "commit:$commit") -TargetAgentId pipeline_monitor -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
& (Join-Path $PSScriptRoot 'Invoke-PostPushPipeline.ps1') -TaskId $TaskId -RepositoryId $RepositoryId -PushWasSuccessful -Branch $branch -Commit $commit -QueuedAfter $queuedAfter -RemediationCycle $RemediationCycle -ConfigPath $ConfigPath -CodexHome $CodexHome
