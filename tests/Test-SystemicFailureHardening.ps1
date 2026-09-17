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

[pscustomobject]@{ Status='passed'; Checks=@('typed review inspection','failure correlation','dispatch contract','safe test retention') }
