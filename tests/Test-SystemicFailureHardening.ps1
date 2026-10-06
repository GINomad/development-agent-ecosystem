[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\systemic-failure-hardening'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null

$reviewPath = Join-Path $OutputRoot 'review.json'
[IO.File]::WriteAllText($reviewPath, (([ordered]@{ reviewedRevision='rev-1'; reviewCoverage=@([ordered]@{ dimension='correctness'; status='covered'; evidence=@('direct') }); findings=@([ordered]@{ id='REV-1' }); findingLifecycle=@([ordered]@{ findingId='REV-1'; status='new'; firstSeenRevision='rev-1'; lastObservedRevision='rev-1' }) } | ConvertTo-Json -Depth 8) + [Environment]::NewLine))
$inspection = & (Join-Path $root 'scripts\Get-ReviewVerificationInput.ps1') -ReviewPath $reviewPath
Assert-True ($inspection.coverage.Count -eq 1 -and $inspection.activeFindingIds[0] -eq 'REV-1' -and $inspection.lifecycle[0].status -eq 'new') 'Canonical review inspection lost typed coverage or lifecycle data.'

$fixtureConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$fixtureConfig.runtime.stateRoot = Join-Path $OutputRoot 'state'
$fixtureConfig.workflow.workspaceScheduling.workspaceRoot = Join-Path $OutputRoot 'workspaces'
$fixtureConfigPath = Join-Path $OutputRoot 'agents.json'
[IO.File]::WriteAllText($fixtureConfigPath, (($fixtureConfig | ConvertTo-Json -Depth 40) + [Environment]::NewLine))
$taskId = 'systemic-hardening-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$task = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $taskId -TaskSelector synthetic -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fixtureConfigPath
$f1 = & (Join-Path $root 'scripts\Write-AgentFailure.ps1') -TaskId $taskId -AgentId review_verifier -Stage failed -Summary 'Non-retryable command parse failure: ParserError: An empty pipe element is not allowed at line 2.' -Diagnostic 'ParserError: An empty pipe element is not allowed at line 2.' -ConfigPath $fixtureConfigPath
$f2 = & (Join-Path $root 'scripts\Write-AgentFailure.ps1') -TaskId $taskId -AgentId orchestrator -Stage failed -Summary 'Execution retry limit reached after 3 identical failures: ParserError: An empty pipe element is not allowed at line 9.' -Diagnostic 'ParserError: An empty pipe element is not allowed at line 9.' -ConfigPath $fixtureConfigPath
Assert-True ($f1.Failure.failureSignature -ne $f2.Failure.failureSignature) 'Occurrence-specific failureSignature unexpectedly collapsed.'
Assert-True ($f1.Failure.rootCauseFingerprint -eq $f2.Failure.rootCauseFingerprint -and $f1.Failure.correlationId -eq $f2.Failure.correlationId) 'Equivalent parser failures were not correlated by normalized root cause.'

# Regression for task-1880262: a Verifier ParserError was attributed to Developer,
# then the same exact run published Verifier PASS seven seconds later.
$staleTaskId = 'stale-terminal-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$staleTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $staleTaskId -TaskSelector task-1880262-stale-verifier -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fixtureConfigPath
$staleRunId = 'run1880262exactbound'
$staleFailure = & (Join-Path $root 'scripts\Write-AgentFailure.ps1') -TaskId $staleTaskId -AgentId developer -ExecutionAgentId review_verifier -ExecutionRunId $staleRunId -Stage failed -Summary 'ParserError from Verifier host was incorrectly attributed to Developer.' -Diagnostic 'ParserError: An empty pipe element is not allowed.' -ConfigPath $fixtureConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $staleTaskId -Status failed -Stage failed -Message 'Synthetic stale host failure.' -ConfigPath $fixtureConfigPath | Out-Null
$staleLedgerPath = Join-Path $staleTask.TaskRoot 'task-ledger.jsonl'
$staleLedgerEvents = @(Get-Content -LiteralPath $staleLedgerPath -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
$failureEvent = @($staleLedgerEvents | Where-Object { [string]$_.type -eq 'agent-failure' -and [string]$_.artifact -eq [string]$staleFailure.FailurePath } | Select-Object -First 1)
$passRecord = [pscustomobject][ordered]@{ eventId=[guid]::NewGuid().ToString('N'); taskId=$staleTaskId; timestampUtc=([DateTime]$failureEvent.timestampUtc).AddSeconds(7).ToString('o'); actor='review_verifier'; type='agent-result'; summary='Verifier PASS.'; artifact=$null; evidence=@("execution-run:$staleRunId",'agent:review_verifier'); targetAgentId=$null }
$staleLedgerEvents += $passRecord
Write-Utf8NoBom -Path $staleLedgerPath -Content ((@($staleLedgerEvents | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine)
$staleReconciliation = & (Join-Path $root 'scripts\Resolve-RecoveredControlPlaneStatuses.ps1') -TaskId $staleTaskId -ConfigPath $fixtureConfigPath
$staleState = Get-Content -LiteralPath (Join-Path $staleTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([string]$staleState.status -eq 'interrupted' -and [string]$staleState.agentStatuses.developer.status -eq 'pending' -and [string]$staleState.agentStatuses.review_verifier.status -eq 'completed') 'Exact-bound Verifier PASS did not supersede the stale misattributed Developer failure.'
Assert-True (@($staleReconciliation.Reconciled) -contains 'developer') 'The stale misattributed failure was not reported as reconciled.'

$suppressedTaskId = 'stale-writer-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$suppressedTask = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $suppressedTaskId -TaskSelector stale-writer-suppression -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fixtureConfigPath
& (Join-Path $root 'scripts\Set-AgentTaskStatus.ps1') -TaskId $suppressedTaskId -AgentId review_verifier -AgentStatus completed -ConfigPath $fixtureConfigPath | Out-Null
$suppressedLedgerPath = Join-Path $suppressedTask.TaskRoot 'task-ledger.jsonl'
$suppressedPass = [ordered]@{ eventId=[guid]::NewGuid().ToString('N'); taskId=$suppressedTaskId; timestampUtc=[DateTime]::UtcNow.ToString('o'); actor='review_verifier'; type='agent-result'; summary='Verifier PASS.'; artifact=$null; evidence=@("execution-run:$staleRunId",'agent:review_verifier'); targetAgentId=$null }
[IO.File]::AppendAllText($suppressedLedgerPath,(($suppressedPass | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
$suppressedFailure = & (Join-Path $root 'scripts\Write-AgentFailure.ps1') -TaskId $suppressedTaskId -AgentId developer -ExecutionAgentId review_verifier -ExecutionRunId $staleRunId -Stage failed -Summary 'Late stale host failure.' -ConfigPath $fixtureConfigPath
$suppressedState = Get-Content -LiteralPath (Join-Path $suppressedTask.TaskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([bool]$suppressedFailure.Stale -and [string]$suppressedFailure.Failure.disposition -eq 'stale-superseded' -and [string]$suppressedState.agentStatuses.developer.status -ne 'failed') 'The failure writer overwrote a newer exact-bound terminal success.'

$safeForeachPipeline = @'
$results = foreach ($path in @('first', 'second')) {
    [pscustomobject]@{ Path = $path }
}
$results | Format-Table -AutoSize | Out-String | Out-Null
'@
$parseErrors = $null
$parseTokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($safeForeachPipeline, [ref]$parseTokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Safe foreach collection formatting must remain valid PowerShell syntax.'

$unsafeControlBlockPipeline = @'
if ($true) {
    [pscustomobject]@{ Path = 'first' }
} | Format-Table -AutoSize | Out-String | Out-Null
'@
$parseErrors = $null
$parseTokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($unsafeControlBlockPipeline, [ref]$parseTokens, [ref]$parseErrors)
Assert-True (@($parseErrors | Where-Object { $_.Message -match 'empty pipe element' }).Count -eq 1) 'Direct pipelines after statement-form control blocks must reproduce the empty-pipe parser failure.'

$reviewerPrompt = Get-Content -LiteralPath (Join-Path $root 'prompts\roles\reviewer.md') -Raw -Encoding UTF8
Assert-True ($reviewerPrompt -match [regex]::Escape('$results = foreach (...) { ... }; $results | Format-Table') -and $reviewerPrompt -match 'parser error') 'Reviewer instructions must prevent direct pipelines after statement-form foreach evidence commands.'
$taskProtocol = Get-Content -LiteralPath (Join-Path $root 'prompts\common\task-protocol.md') -Raw -Encoding UTF8
Assert-True ($taskProtocol -match 'never pipe directly from a statement-form control block' -and $taskProtocol -match 'empty pipe element' -and $taskProtocol -match 'foreach`, `if`, `switch`, `try`, or `function') 'Shared workflow instructions must prevent empty-pipe parser failures for every role.'

$createdEvent = Get-Content -LiteralPath (Join-Path $task.TaskRoot 'task-ledger.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'task-created' | Select-Object -First 1
$null = & (Join-Path $root 'scripts\Set-WorkflowInputRoute.ps1') -TaskId $taskId -SourceEventId $createdEvent.eventId -InputKind task-intake -TargetAgentIds reviewer -ExecutionMode review-only -Rationale synthetic -Confidence high -ConfigPath $fixtureConfigPath
$validDispatch = & (Join-Path $root 'scripts\Test-WorkflowDispatchContract.ps1') -TaskId $taskId -TargetAgentId reviewer -ConfigPath $fixtureConfigPath
Assert-True ($validDispatch.Status -eq 'valid') 'Valid review-only dispatch was rejected.'
$invalidDispatchRejected = $false
try { & (Join-Path $root 'scripts\Test-WorkflowDispatchContract.ps1') -TaskId $taskId -TargetAgentId pipeline_monitor -ConfigPath $fixtureConfigPath | Out-Null } catch { $invalidDispatchRejected = $true }
Assert-True $invalidDispatchRejected 'Out-of-mode target dispatch was accepted.'

$unroutedTaskId = 'unrouted-hardening-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$null = & (Join-Path $root 'scripts\New-AgentTask.ps1') -TaskId $unroutedTaskId -TaskSelector synthetic -Mode manual -RepositoryIds azure-planningspace-ps-excel-agent -ConfigPath $fixtureConfigPath
$unroutedRejected = $false
try { & (Join-Path $root 'scripts\Test-WorkflowDispatchContract.ps1') -TaskId $unroutedTaskId -TargetAgentId developer -ConfigPath $fixtureConfigPath | Out-Null } catch { $unroutedRejected = $true }
Assert-True $unroutedRejected 'Executable unrouted target dispatch was accepted.'
$prepareOnlyContract = & (Join-Path $root 'scripts\Test-WorkflowDispatchContract.ps1') -TaskId $unroutedTaskId -TargetAgentId developer -AllowUnroutedTarget -ConfigPath $fixtureConfigPath
Assert-True ($prepareOnlyContract.Status -eq 'unrouted') 'Explicit non-executing unrouted inspection was rejected.'

$retentionRoot = Join-Path $OutputRoot 'retention'
$marked = Join-Path $retentionRoot 'marked-old'; $unmarked = Join-Path $retentionRoot 'user-old'
New-Item -ItemType Directory -Path $marked,$unmarked -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $marked '.ecosystem-test-output.json'),'{}')
(Get-Item -LiteralPath $marked).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
(Get-Item -LiteralPath $unmarked).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-30)
$removed = @(& (Join-Path $root 'scripts\Remove-StaleTestOutput.ps1') -OutputRoot $retentionRoot -RetentionDays 14)
Assert-True ($removed.Count -eq 1 -and -not (Test-Path -LiteralPath $marked) -and (Test-Path -LiteralPath $unmarked)) 'Retention did not remove only marked stale output.'

[pscustomobject]@{ Status='passed'; Checks=@('typed review inspection','failure correlation','stale exact-bound terminal reconciliation','safe foreach collection formatting','dispatch contract','safe test retention') }
