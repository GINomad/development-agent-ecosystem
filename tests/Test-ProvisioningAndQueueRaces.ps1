[CmdletBinding()]
param(
    [string]$ConfigPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string]$OutputRoot=(Join-Path ([IO.Path]::GetTempPath()) ('pq-'+[guid]::NewGuid().ToString('N').Substring(0,6)))
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\AgentEcosystem.psm1') -Force
$null=New-Item -ItemType Directory -Path $OutputRoot -Force
$config=Get-EcosystemConfig -ConfigPath $ConfigPath
$config.runtime.stateRoot=Join-Path $OutputRoot 'state'
$config.workflow.workspaceScheduling.coordinatorStatePath=Join-Path $config.runtime.stateRoot 'coordinator.json'
$config.workflow.workspaceScheduling.workspaceRoot=Join-Path $OutputRoot 'clones'
$config.workflow.workspaceScheduling.maxActiveTasks=2
$nativeGit=(Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$source=Join-Path $OutputRoot 'source'
$null=New-Item -ItemType Directory -Path $source -Force
$null=& $nativeGit -C $source init -b main 2>&1
if($LASTEXITCODE){throw 'Cannot initialize offline fixture.'}
Write-Utf8NoBom -Path (Join-Path $source 'fixture.txt') -Content 'offline fixture'
& $nativeGit -C $source add fixture.txt
$null=& $nativeGit -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit -m fixture 2>&1
if($LASTEXITCODE){throw 'Cannot commit offline fixture.'}
$repository=$config.repositories[0]
$canonicalOrigin=[string]$repository.url
& $nativeGit -C $source remote add origin $canonicalOrigin
$repository|Add-Member -NotePropertyName workspaceCloneSource -NotePropertyValue $source -Force
$repository|Add-Member -NotePropertyName workspaceBaseBranch -NotePropertyValue main -Force
$repositoryId=[string]$repository.id
$fixtureConfig=Join-Path $OutputRoot 'agents.json'
Write-Utf8NoBom -Path $fixtureConfig -Content ($config|ConvertTo-Json -Depth 80)
$state=[string]$config.runtime.stateRoot
$coordinator=[string]$config.workflow.workspaceScheduling.coordinatorStatePath
function Save-Coordinator($Leases,$Queue=@()) {
    Write-Utf8NoBomAtomic -Path $coordinator -Content ((@{schemaVersion='2.0.0';leases=@($Leases);queuedTasks=@($Queue);updatedAtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 15)+[Environment]::NewLine)
}
function Save-Task([string]$Id,[string]$Run='',[string]$Lease='',[string]$Status='created',[int]$Age=0) {
    $path=Join-Path $state "tasks\$Id\task.json"
    $task=@{taskId=$Id;taskName=$Id;taskType='feature';branchName=('features/'+$Id);status=$Status;currentStage='fixture';lastMessage='fixture';createdAtUtc=[DateTime]::UtcNow.AddMinutes($Age).ToString('o');updatedAtUtc=[DateTime]::UtcNow.ToString('o');repositoryIds=@($repositoryId);executionRunId=$Run;workspaceLeaseId=$Lease;agentStatuses=@{}}
    Write-Utf8NoBomAtomic -Path $path -Content ($task|ConvertTo-Json -Depth 15)
    return $path
}
function Wait-File([string]$Path) {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not(Test-Path -LiteralPath $Path)){if([DateTime]::UtcNow -gt $deadline){throw "Barrier timed out: $Path"};Start-Sleep -Milliseconds 20}
}
Save-Coordinator @()
$switch=Join-Path $root 'scripts\Switch-TaskWorkspace.ps1'
$release=Join-Path $root 'scripts\Release-TaskWorkspaceLease.ps1'
$ids=@('fifo-one','fifo-two','fifo-three')
foreach($index in 0..2){$null=Save-Task $ids[$index] '' '' created (-3+$index)}
$null=Save-Task 'fifo-anchor' '' '' created -4
$anchor=& $switch -TaskId 'fifo-anchor' -RunId ('0'*32) -ConfigPath $fixtureConfig
$first=& $switch -TaskId $ids[0] -RunId ('a'*32) -ConfigPath $fixtureConfig
if($first.Status -ne 'active'){throw 'First FIFO task was not admitted.'}
$second=& $switch -TaskId $ids[1] -RunId ('b'*32) -ConfigPath $fixtureConfig
$third=& $switch -TaskId $ids[2] -RunId ('c'*32) -ConfigPath $fixtureConfig
if($second.Status -ne 'queued' -or $third.Status -ne 'queued'){throw 'Capacity did not register both waiting tasks.'}
& $release -TaskId $ids[0] -LeaseId $first.LeaseId -ConfigPath $fixtureConfig|Out-Null
$late=& $switch -TaskId $ids[2] -RunId ('c'*32) -ConfigPath $fixtureConfig
if($late.Status -ne 'queued'){throw 'Later FIFO task bypassed older durable queue entry.'}
$second=& $switch -TaskId $ids[1] -RunId ('b'*32) -ConfigPath $fixtureConfig
if($second.Status -ne 'active'){throw 'Oldest queued task was starved by another queued task.'}
& $release -TaskId $ids[1] -LeaseId $second.LeaseId -ConfigPath $fixtureConfig|Out-Null
$third=& $switch -TaskId $ids[2] -RunId ('c'*32) -ConfigPath $fixtureConfig
if($third.Status -ne 'active'){throw 'Queue did not drain to third task.'}
& $release -TaskId $ids[2] -LeaseId $third.LeaseId -ConfigPath $fixtureConfig|Out-Null

& $release -TaskId 'fifo-anchor' -LeaseId $anchor.LeaseId -ConfigPath $fixtureConfig|Out-Null
$terminalPath=Save-Task 'queue-terminal' '' '' completed -5
$terminalEntry=@{taskId='queue-terminal';runId=('8'*32);createdAtUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o');queuedAtUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')}
Save-Coordinator @() @($terminalEntry)
$null=Save-Task 'queue-after-terminal' '' '' created
$afterTerminal=& $switch -TaskId 'queue-after-terminal' -RunId ('7'*32) -ConfigPath $fixtureConfig
if($afterTerminal.Status -ne 'active'){throw 'Terminal durable queue row starved a later task.'}
& $release -TaskId 'queue-after-terminal' -LeaseId $afterTerminal.LeaseId -ConfigPath $fixtureConfig|Out-Null
$freshPath=Save-Task 'queue-fresh-resume' '' '' failed -4
$freshTask=Get-Content -LiteralPath $freshPath -Raw|ConvertFrom-Json
$freshTask.updatedAtUtc=[DateTime]::UtcNow.AddMinutes(-2).ToString('o')
Write-Utf8NoBom -Path $freshPath -Content ($freshTask|ConvertTo-Json -Depth 12)
$freshEntry=@{taskId='queue-fresh-resume';runId=('6'*32);createdAtUtc=[DateTime]::UtcNow.AddMinutes(-4).ToString('o');queuedAtUtc=[DateTime]::UtcNow.ToString('o')}
Save-Coordinator @() @($freshEntry)
$null=Save-Task 'queue-after-resume' '' '' created
$afterResume=& $switch -TaskId 'queue-after-resume' -RunId ('5'*32) -PrepareOnly -ConfigPath $fixtureConfig
if($afterResume.Status -ne 'would-queue'){throw 'Fresh resumed registration was incorrectly pruned from a prior failed task snapshot.'}

$taskId='provision-race';$oldRun='d'*32;$oldLease='e'*32;$newRun='f'*32;$newLease='9'*32
$null=Save-Task $taskId $oldRun $oldLease running
$lease=@{taskId=$taskId;runId=$oldRun;leaseId=$oldLease;lifecycle='provisioning';heartbeatAtUtc=[DateTime]::UtcNow.ToString('o');repositories=@($repositoryId)}
Save-Coordinator @($lease)
$gateName='dae-provision-'+[guid]::NewGuid().ToString('N')
$gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$gateName)
$oldReady=Join-Path $OutputRoot 'old-clone-ready';$newEntered=Join-Path $OutputRoot 'new-entered';$newClone=Join-Path $OutputRoot 'new-clone-started'
$provision=Join-Path $root 'scripts\Provision-TaskWorkspace.ps1'
$oldJob=$null;$newJob=$null
try {
    $oldJob=Start-Job -ScriptBlock {
        param($Script,$Config,$Task,$Repo,$Run,$Lease,$Git,$Ready,$Gate)
        $global:FixtureGit=$Git;$global:FixtureReady=$Ready;$global:FixtureGate=$Gate
        function global:git {
            $forward=@($args)
            if($forward -contains 'clone') {
                [IO.File]::WriteAllText($global:FixtureReady,'ready')
                $wait=[Threading.EventWaitHandle]::OpenExisting($global:FixtureGate)
                try{if(-not $wait.WaitOne(20000)){throw 'Clone gate timed out.'}}finally{$wait.Dispose()}
            }
            & $global:FixtureGit @forward
            $global:LASTEXITCODE=$LASTEXITCODE
        }
        try{$result=& $Script -TaskId $Task -RepositoryIds @($Repo) -RunId $Run -LeaseId $Lease -ConfigPath $Config;[pscustomobject]@{Ok=$true;Result=$result}}
        catch{[pscustomobject]@{Ok=$false;Message=$_.Exception.Message}}
    } -ArgumentList $provision,$fixtureConfig,$taskId,$repositoryId,$oldRun,$oldLease,$nativeGit,$oldReady,$gateName
    Wait-File $oldReady
    $null=Save-Task $taskId $newRun $newLease running
    $lease.runId=$newRun;$lease.leaseId=$newLease
    Save-Coordinator @($lease)
    $newJob=Start-Job -ScriptBlock {
        param($Script,$Config,$Task,$Repo,$Run,$Lease,$Git,$Entered,$Clone)
        $global:FixtureGit=$Git;$global:FixtureClone=$Clone
        function global:git {$forward=@($args);if($forward -contains 'clone'){[IO.File]::WriteAllText($global:FixtureClone,'clone')}; & $global:FixtureGit @forward;$global:LASTEXITCODE=$LASTEXITCODE}
        [IO.File]::WriteAllText($Entered,'entered')
        try{$result=& $Script -TaskId $Task -RepositoryIds @($Repo) -RunId $Run -LeaseId $Lease -ConfigPath $Config;[pscustomobject]@{Ok=$true;Result=$result}}
        catch{[pscustomobject]@{Ok=$false;Message=$_.Exception.Message}}
    } -ArgumentList $provision,$fixtureConfig,$taskId,$repositoryId,$newRun,$newLease,$nativeGit,$newEntered,$newClone
    Wait-File $newEntered
    if(Test-Path -LiteralPath $newClone){throw 'Replacement provisioning entered clone while old cleanup still owned the task operation lock.'}
    $null=$gate.Set()
    $null=Wait-Job -Job @($oldJob,$newJob) -Timeout 40
    if($oldJob.State -ne 'Completed' -or $newJob.State -ne 'Completed'){throw 'Provisioning race jobs did not terminate.'}
    $oldResult=@(Receive-Job $oldJob -ErrorAction Stop)|Select-Object -Last 1
    $newResult=@(Receive-Job $newJob -ErrorAction Stop)|Select-Object -Last 1
    if($oldResult.Ok -or -not $newResult.Ok){throw ('Stale/new provisioning outcome was wrong: '+($oldResult|ConvertTo-Json -Compress)+' '+($newResult|ConvertTo-Json -Compress))}
    $manifest=Get-Content -LiteralPath (Join-Path $state "tasks\$taskId\workspaces\$repositoryId.json") -Raw|ConvertFrom-Json
    if($manifest.runId -ne $newRun -or $manifest.leaseId -ne $newLease -or -not(Test-Path -LiteralPath (Join-Path $manifest.clonePath '.git'))){throw 'Stale provision overwrote or deleted replacement clone/manifest.'}
} finally {
    $null=$gate.Set()
    foreach($job in @($oldJob,$newJob)){if($job){if($job.State -eq 'Running'){Stop-Job $job};Remove-Job $job -Force -ErrorAction SilentlyContinue}}
    $gate.Dispose()
}
# Exercise the exact post-validation/pre-write interval using the production
# helper and an explicit atomic-write barrier. An old implementation releases
# the coordinator before this barrier and permits lease replacement here.
$helperAst=[Management.Automation.Language.Parser]::ParseFile($provision,[ref]$null,[ref]$null)
$helper=$helperAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-WorkspaceManifestLocked'},$true).Extent.Text
$writeGateName='dae-commit-'+[guid]::NewGuid().ToString('N')
$writeGate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$writeGateName)
$writeReady=Join-Path $OutputRoot 'atomic-write-ready'
$commitJob=$null
try {
    $commitJob=Start-Job -ScriptBlock {
        param($Module,$Helper,$Config,$Coordinator,$Task,$Run,$Lease,$ManifestPath,$Manifest,$Ready,$Gate)
        Import-Module $Module -Force
        $script:AtomicImplementation=(Get-Command Write-Utf8NoBomAtomic).ScriptBlock
        $script:Ready=$Ready;$script:Gate=$Gate
        function Write-Utf8NoBomAtomic {
            param([string]$Path,[string]$Content)
            [IO.File]::WriteAllText($script:Ready,'ready')
            $gate=[Threading.EventWaitHandle]::OpenExisting($script:Gate)
            try{if(-not $gate.WaitOne(15000)){throw 'Commit gate timed out.'}}finally{$gate.Dispose()}
            & $script:AtomicImplementation -Path $Path -Content $Content
        }
        $config=$Config;$coordinatorPath=$Coordinator;$TaskId=$Task;$RunId=$Run;$LeaseId=$Lease
        $manifestLockPath=Join-Path (Split-Path -Parent (Split-Path -Parent $ManifestPath)) 'workspace-manifests.lock'
        $lockMetricsPath=$null;$lockCorrelationId='atomic-commit-fixture'
        . ([scriptblock]::Create($Helper))
        Write-WorkspaceManifestLocked -Path $ManifestPath -Manifest $Manifest
        'committed'
    } -ArgumentList (Join-Path $root 'scripts/AgentEcosystem.psm1'),$helper,$config,$coordinator,$taskId,$newRun,$newLease,(Join-Path $state "tasks\$taskId\workspaces\$repositoryId.json"),$manifest,$writeReady,$writeGateName
    Wait-File $writeReady
    $replacementWasBlocked=$false
    try { Invoke-EcosystemFileLock -LockPath ($coordinator+'.lock') -TimeoutSeconds 1 -Action { 'replacement-escaped' }|Out-Null }
    catch { $replacementWasBlocked=$_.Exception.Message -match 'Timed out waiting for exclusive lock' }
    if(-not $replacementWasBlocked){throw 'Lease replacement escaped during the post-validation/pre-write window.'}
    $null=$writeGate.Set()
    $null=Wait-Job $commitJob -Timeout 20
    $committed=@(Receive-Job $commitJob -ErrorAction Stop)
    if($commitJob.State -ne 'Completed' -or $committed[-1] -ne 'committed'){throw 'Atomic manifest commit did not complete after barrier release.'}
} finally {
    $null=$writeGate.Set()
    if($commitJob){if($commitJob.State -eq 'Running'){Stop-Job $commitJob};Remove-Job $commitJob -Force -ErrorAction SilentlyContinue}
    $writeGate.Dispose()
}
[pscustomobject]@{Passed=$true;Checks=@('three tasks drain FIFO without starvation','terminal queue pruned and fresh resume registration preserved','stale clone/provision/cleanup versus replacement barrier','atomic post-validation/pre-write manifest commit barrier');OutputRoot=$OutputRoot}
