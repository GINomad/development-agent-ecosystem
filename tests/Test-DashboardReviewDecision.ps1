[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output\dashboard-review-decision')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$taskId = 'dashboard-review-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$runRoot = Join-Path $OutputRoot $taskId
$fixtureRoot = Join-Path $runRoot 'fixture'
$stateRoot = Join-Path $runRoot 'state'
$fixtureConfigPath = Join-Path $fixtureRoot 'config\agents.json'

function Write-JsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-RequestFails {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Expected error matching '$Pattern', received: $($_.Exception.Message)" }
        return
    }
    throw "Expected request to fail with '$Pattern'."
}

function Get-FreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function New-ReviewArtifact {
    param([string] $Revision = 'reviewed-1', [string] $FindingId = 'REV-101')
    $dimensions = @('requirements','correctness','security','regression','testing','maintainability','performance','concurrency','configuration-deployment','documentation')
    return [ordered]@{
        taskId = $taskId
        reviewedRevision = $Revision
        requirementsRevision = 'requirements-1'
        requirementTraceability = @([ordered]@{ requirementId='REQ-1'; requirementText='Synthetic dashboard approval contract.'; implementationStatus='verified'; codeReferences=@([ordered]@{ repositoryId='synthetic'; filePath='src/example.ps1'; startLine=1; evidence='Synthetic fixture.' }); testEvidence=@('Synthetic fixture'); notes='Synthetic fixture.' })
        reviewCoverage = @($dimensions | ForEach-Object { [ordered]@{ dimension=$_; status='covered'; evidence=@("Evidence for $_"); notes='Synthetic coverage.' } })
        findings = @([ordered]@{ id=$FindingId; severity='high'; category='correctness'; location='src/example.ps1:1'; evidence='Synthetic finding.'; impact='Synthetic impact.'; correctionDirection='Synthetic correction.'; decisionStatus='proposed' })
        heldScopeViolations = @()
        agentProcessFindings = @()
        findingLifecycle = @([ordered]@{ findingId=$FindingId; status='new'; firstSeenRevision=$Revision; lastObservedRevision=$Revision; evidence='Synthetic lifecycle evidence.' })
        summary = 'Synthetic review for dashboard approval endpoint.'
    }
}

function New-VerificationArtifact {
    param([Parameter(Mandatory)] $Review, [Parameter(Mandatory)][string] $ReviewSha256, [ValidateSet('confirmed','rejected')][string] $Verdict = 'confirmed')
    return [ordered]@{
        taskId = $taskId
        reviewedRevision = [string]$Review.reviewedRevision
        reviewArtifactSha256 = $ReviewSha256
        verificationStatus = 'passed'
        coverageVerification = @($Review.reviewCoverage | ForEach-Object { [ordered]@{ dimension=[string]$_.dimension; claimedStatus='covered'; verdict='confirmed'; evidence=@('Synthetic independent evidence.'); falsificationAttempts=@('Synthetic falsification attempt.'); notes='Synthetic verification.' } })
        findingVerifications = @([ordered]@{ findingId='REV-101'; findingKind='product'; verdict=$Verdict; evidence=@('Synthetic independent evidence.'); falsificationAttempts=@('Synthetic falsification attempt.'); notes='Synthetic verifier verdict.' })
        lifecycleVerifications = @([ordered]@{ findingId='REV-101'; claimedStatus='new'; verdict='confirmed'; evidence=@('Synthetic independent lifecycle evidence.'); notes='Synthetic lifecycle verification.' })
        summary = 'Synthetic independent verification.'
    }
}

function Start-FixtureDashboard {
    param([bool] $RequiresDashboardApproval, [int] $Requests = 1)
    $config = Get-Content -LiteralPath $fixtureConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = Get-FreePort
    $config.runtime.stateRoot = $stateRoot
    $config.ui.listenAddress = '127.0.0.1'
    $config.ui.port = $port
    $config.ui.openBrowser = $false
    $config.runtime.elevatedFallback.requiresDashboardApproval = $RequiresDashboardApproval
    Write-JsonFile -Path $fixtureConfigPath -Value $config
    $stdout = Join-Path $runRoot ("dashboard-$port.out.log")
    $stderr = Join-Path $runRoot ("dashboard-$port.err.log")
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',(Join-Path $fixtureRoot 'scripts\Start-AgentDashboard.ps1'),'-NoOpen','-MaxRequests',$Requests,'-ConfigPath',$fixtureConfigPath) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (Test-Path -LiteralPath $stdout) {
            $line = Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($line -match 'http://127\.0\.0\.1:(?<port>\d+)/\?token=(?<token>\S+)$') {
                return [pscustomobject]@{ Process=$process; Url="http://127.0.0.1:$($Matches.port)/"; Token=$Matches.token; StdErr=$stderr }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $process.HasExited) { $process.Kill() }
    throw "Fixture dashboard did not start. $((Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))"
}

function Invoke-FixtureApi {
    param([Parameter(Mandatory)] $Server, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Body)
    if ($Body.ContainsKey('expectedRevision')) {
        $current = Get-Content -LiteralPath (Join-Path $stateRoot "tasks\$taskId\task.json") -Raw | ConvertFrom-Json
        $Body.expectedRevision = [int]$current.revision
    }
    try {
        return Invoke-RestMethod -Uri ($Server.Url + $Path.TrimStart('/')) -Method Post -Headers @{ 'X-Ecosystem-Token'=$Server.Token } -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20)
    }
    catch {
        $detail = [string]$_.ErrorDetails.Message
        if (-not [string]::IsNullOrWhiteSpace($detail)) { throw "HTTP request failed: $detail" }
        throw
    }
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $fixtureRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $fixtureRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'dashboard') -Destination $fixtureRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'knowledge') -Destination $fixtureRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $root 'plugins') -Destination $fixtureRoot -Recurse -Force
# Production configuration rightly rejects this policy combination under the standing host policy.
# The copied module relaxes only that startup invariant so the production endpoint's otherwise unreachable
# approval-required branch can be exercised without changing the real configuration.
$fixtureModulePath = Join-Path $fixtureRoot 'scripts\AgentEcosystem.psm1'
$fixtureModule = [IO.File]::ReadAllText($fixtureModulePath)
$policyInvariant = "if (-not [bool]`$Config.runtime.elevatedFallback.useByDefault -or [bool]`$Config.runtime.elevatedFallback.requiresDashboardApproval -or [string]`$Config.runtime.elevatedFallback.sandboxMode -ne 'danger-full-access') { throw 'Workflow host-compatible execution must be enabled by default under the standing user authorization.' }"
if ($fixtureModule.IndexOf($policyInvariant) -lt 0) { throw 'Fixture module policy invariant was not found.' }
$fixtureModule = $fixtureModule.Replace($policyInvariant, 'if ($false) { throw ''fixture-only policy invariant'' }')
[IO.File]::WriteAllText($fixtureModulePath, $fixtureModule, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $root 'prompts') -Destination $fixtureRoot -Recurse -Force

# The fixture executes the production route and targeted-resume helper unchanged. Only runspace launch is replaced,
# so the scheduled branch writes ordinary task status and ledger evidence without starting a workflow.
$dashboardPath = Join-Path $fixtureRoot 'scripts\Start-AgentDashboard.ps1'
$dashboardSource = Get-Content -LiteralPath $dashboardPath -Raw -Encoding UTF8
$targetedFunction = '(?s)function Start-ScriptRunspace \{.*?\n\}\r?\n\r?\nfunction Clear-CompletedScriptRunspaces'
$replacement = @'
function Start-ScriptRunspace {
    param([string] $ScriptPath, [hashtable] $Parameters, [string] $TaskId)
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'fail-launch')) { throw 'Synthetic launch failure.' }
    [IO.File]::AppendAllText((Join-Path $stateRoot 'launches.jsonl'), (($Parameters | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine))
    [pscustomobject][ordered]@{ runId='fixture-run'; taskId=$TaskId }
}
function Clear-CompletedScriptRunspaces
'@
if ([regex]::Matches($dashboardSource, $targetedFunction).Count -ne 1) { throw 'Dashboard fixture could not locate the production targeted-resume helper.' }
$dashboardSource = [regex]::Replace($dashboardSource, $targetedFunction, $replacement)
$activeFixture = @'
$scriptRuns = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath (Join-Path $stateRoot 'active-task')) {
    $scriptRuns.Add([pscustomobject]@{ taskId=[IO.File]::ReadAllText((Join-Path $stateRoot 'active-task')); Async=[pscustomobject]@{ IsCompleted=$false }; PowerShell=[PowerShell]::Create() })
}
'@
$dashboardSource = $dashboardSource.Replace('$scriptRuns = [Collections.Generic.List[object]]::new()', $activeFixture)
[IO.File]::WriteAllText($dashboardPath, $dashboardSource, [Text.UTF8Encoding]::new($false))

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config.runtime.stateRoot = $stateRoot
Write-JsonFile -Path $fixtureConfigPath -Value $config
& (Join-Path $fixtureRoot 'scripts\New-AgentTask.ps1') -TaskId $taskId -TaskSelector 'synthetic-dashboard-review-decision' -Mode manual -RepositoryIds 'azure-planningspace-ps-excel-agent' -ConfigPath $fixtureConfigPath | Out-Null
$taskRoot = Join-Path $stateRoot "tasks\$taskId"
$reviewPath = Join-Path $taskRoot 'review-result.json'
$verificationPath = Join-Path $taskRoot 'review-verification.json'
$review = New-ReviewArtifact
Write-JsonFile -Path $reviewPath -Value $review
Import-Module (Join-Path $fixtureRoot 'scripts\AgentEcosystem.psm1') -Force
$reviewSha256 = Get-EcosystemFileSha256 -Path $reviewPath
Write-JsonFile -Path $verificationPath -Value (New-VerificationArtifact -Review $review -ReviewSha256 $reviewSha256)

$task = Get-Content -LiteralPath (Join-Path $taskRoot 'task.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$guard = @{ expectedRevision=[int]$task.revision; runId=''; leaseId='' }
$approval = @{ findingId='REV-101'; decision='approved'; note='Approved in isolated dashboard test.'; expectedReviewedRevision='reviewed-1'; expectedReviewArtifactSha256=$reviewSha256 } + $guard

# A plain Developer reply remains a comment and reports the pre-existing idle state; it cannot create a decision.
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$plain = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/comments" -Body (@{ text='approved'; targetAgentId='developer'; reviewFindingId='REV-101' })
Assert-Equal $plain.status 'saved' 'Plain reviewer reply must be saved as a comment.'
Assert-Equal $plain.dispatch.status 'idle-awaiting-approval' 'Plain reviewer reply must not start Developer.'
if (Test-Path -LiteralPath (Join-Path $taskRoot 'review-decisions.json')) { throw 'Plain reviewer reply must not create a formal decision.' }

# Formal approval records the exact review SHA and schedules the fake targeted branch once.
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$scheduled = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $approval
Assert-Equal $scheduled.status 'approved' 'Formal approval response status is incorrect.'
Assert-Equal $scheduled.dispatch.status 'scheduled' 'Idle formal approval must schedule Developer.'
Assert-Equal $scheduled.decision.reviewArtifactSha256 $reviewSha256 'Formal approval must persist the exact current review SHA.'

# Retrying uses the resume contract and does not add a second decision.
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$resume = $approval.Clone(); $resume.decision = 'resume'
$retried = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $resume
Assert-Equal $retried.dispatch.status 'scheduled' 'A current approved finding must be restartable.'
$decisions = Get-Content -LiteralPath (Join-Path $taskRoot 'review-decisions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal @($decisions.decisions).Count 1 'Resume must not create a duplicate formal decision.'

# Policy remains authoritative: a recorded approval cannot claim that Developer started.
$review = New-ReviewArtifact -Revision 'reviewed-2'
Write-JsonFile -Path $reviewPath -Value $review
$reviewSha256 = Get-EcosystemFileSha256 -Path $reviewPath
Write-JsonFile -Path $verificationPath -Value (New-VerificationArtifact -Review $review -ReviewSha256 $reviewSha256)
$approval.expectedReviewedRevision = 'reviewed-2'; $approval.expectedReviewArtifactSha256 = $reviewSha256
$server = Start-FixtureDashboard -RequiresDashboardApproval $true
$policy = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $approval
Assert-Equal $policy.dispatch.status 'approval-required' 'Configured dashboard approval policy must block automatic start.'

# Stale review identity and a verifier-rejected finding fail before a decision or a false dispatch response.
$stale = $approval.Clone(); $stale.expectedReviewArtifactSha256 = ('0' * 64)
$server = Start-FixtureDashboard -RequiresDashboardApproval $true
Assert-RequestFails -Pattern 'review changed after this dashboard view was loaded' -Action { Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $stale | Out-Null }
$rejected = New-VerificationArtifact -Review $review -ReviewSha256 $reviewSha256 -Verdict rejected
Write-JsonFile -Path $verificationPath -Value $rejected
$server = Start-FixtureDashboard -RequiresDashboardApproval $true
Assert-RequestFails -Pattern 'current verifier result does not permit' -Action { Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $approval | Out-Null }

# Rejected current verification must also block retry of a previously saved approval.
$resume = $approval.Clone(); $resume.decision = 'resume'
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
Assert-RequestFails -Pattern 'current verifier result does not permit' -Action { Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $resume | Out-Null }
Write-JsonFile -Path $verificationPath -Value (New-VerificationArtifact -Review $review -ReviewSha256 $reviewSha256)

# An active in-host run must not call the launch helper again.
$launchesPath = Join-Path $stateRoot 'launches.jsonl'
$launchCount = @(Get-Content -LiteralPath $launchesPath).Count
[IO.File]::WriteAllText((Join-Path $stateRoot 'active-task'), $taskId)
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$active = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $resume
Assert-Equal $active.dispatch.status 'queued-for-checkpoint' 'Active workflow must not launch a duplicate.'
Assert-Equal @(Get-Content -LiteralPath $launchesPath).Count $launchCount 'Active workflow launched a duplicate.'
Remove-Item -LiteralPath (Join-Path $stateRoot 'active-task')

# Failed dispatch preserves approval for retry.
[IO.File]::WriteAllText((Join-Path $stateRoot 'fail-launch'), '1')
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$failed = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $approval
Assert-Equal $failed.dispatch.status 'failed' 'Launch failure must be reported separately from saved approval.'
Remove-Item -LiteralPath (Join-Path $stateRoot 'fail-launch')
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
$retried = Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $resume
Assert-Equal $retried.dispatch.status 'scheduled' 'Saved approval must be retryable after launch failure.'
$parameters = Get-Content -LiteralPath $launchesPath | Select-Object -Last 1 | ConvertFrom-Json
Assert-Equal $parameters.TargetAgentId 'developer' 'Targeted launch must address Developer.'
Assert-Equal $parameters.Resume $true 'Targeted launch must resume the task.'
Assert-Equal $parameters.ContinueChain $true 'Targeted launch must retain continuation.'
if ($parameters.PSObject.Properties['ElevatedApproved']) { throw 'Approval endpoint must not override execution authorization.' }

# A newer rejection invalidates an earlier approval.
& (Join-Path $fixtureRoot 'scripts\Set-ReviewDecision.ps1') -TaskId $taskId -FindingId REV-101 -Decision rejected -DecidedBy user -ConfigPath $fixtureConfigPath | Out-Null
$server = Start-FixtureDashboard -RequiresDashboardApproval $false
Assert-RequestFails -Pattern 'current formal approval is required' -Action { Invoke-FixtureApi -Server $server -Path "/api/tasks/$taskId/review-decisions" -Body $resume | Out-Null }

[pscustomobject][ordered]@{
    Status = 'passed'
    TaskId = $taskId
    OutputRoot = $runRoot
    Checks = @('plain comment does not approve', 'exact-SHA approval', 'idle scheduled', 'resume avoids duplicate decision', 'approval-required policy', 'stale review rejected', 'verifier-rejected finding blocked', 'resume verifier revalidation', 'active run not duplicated', 'failed dispatch retry', 'targeted runner parameters', 'latest decision governs retry')
}
