[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][string] $Workspace,
    [string[]] $PesterPath = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function Invoke-GitChecked {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& git -C $script:resolvedWorkspace @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string]$_ })
}

$resolvedWorkspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path)
$repositoryRoot = (Invoke-GitChecked -Arguments @('rev-parse','--show-toplevel') | Select-Object -First 1).Trim()
if ([IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') -ne $resolvedWorkspace.TrimEnd('\')) {
    throw "Workspace must be the Git repository root: $resolvedWorkspace"
}

$branch = (Invoke-GitChecked -Arguments @('rev-parse','--abbrev-ref','HEAD') | Select-Object -First 1).Trim()
$headCommit = (Invoke-GitChecked -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()
$upstream = (Invoke-GitChecked -Arguments @('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}') | Select-Object -First 1).Trim()
$upstreamDivergenceText = (Invoke-GitChecked -Arguments @('rev-list','--left-right','--count',"$upstream...HEAD") | Select-Object -First 1).Trim()
$upstreamDivergenceParts = @($upstreamDivergenceText -split '\s+' | Where-Object { $_ -ne '' })
if ($upstreamDivergenceParts.Count -ne 2) { throw "Unexpected git upstream divergence result: $upstreamDivergenceText" }
$upstreamBehindCount = [int]$upstreamDivergenceParts[0]
$upstreamAheadCount = [int]$upstreamDivergenceParts[1]
$statusLines = @(Invoke-GitChecked -Arguments @('status','--porcelain'))

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
if (-not (Test-Path -LiteralPath $taskRoot -PathType Container)) { throw "Task '$TaskId' was not found." }
$taskWorkspaces = @(& (Join-Path $PSScriptRoot 'Resolve-TaskWorkspace.ps1') -TaskId $TaskId -AllowReleased -ConfigPath $ConfigPath -CodexHome $CodexHome)
$taskWorkspace = @($taskWorkspaces | Where-Object { [IO.Path]::GetFullPath([string]$_.Path).TrimEnd('\') -eq $resolvedWorkspace.TrimEnd('\') }) | Select-Object -First 1
if (-not $taskWorkspace) { throw "Workspace '$resolvedWorkspace' is not the persisted task workspace for '$TaskId'." }
$taskBaseSha = [string]$taskWorkspace.BaseSha
if (-not $taskBaseSha) { throw "Task workspace manifest for '$TaskId' does not record baseSha." }
$taskBaseCommit = (Invoke-GitChecked -Arguments @('rev-parse','--verify',"$taskBaseSha^{commit}") | Select-Object -First 1).Trim()
$taskMergeBase = (Invoke-GitChecked -Arguments @('merge-base',$taskBaseCommit,'HEAD') | Select-Object -First 1).Trim()
if ($taskMergeBase -ne $taskBaseCommit) { throw "Task workspace manifest baseSha '$taskBaseCommit' is not an ancestor of HEAD '$headCommit'." }
$taskDivergenceText = (Invoke-GitChecked -Arguments @('rev-list','--left-right','--count',"$taskBaseCommit...HEAD") | Select-Object -First 1).Trim()
$taskDivergenceParts = @($taskDivergenceText -split '\s+' | Where-Object { $_ -ne '' })
if ($taskDivergenceParts.Count -ne 2) { throw "Unexpected task-base divergence result: $taskDivergenceText" }
$taskBehindCount = [int]$taskDivergenceParts[0]
$taskAheadCount = [int]$taskDivergenceParts[1]

$pesterResults = [Collections.Generic.List[object]]::new()
$pesterCommand = Get-Command Invoke-Pester -ErrorAction Stop
$index = 0
foreach ($path in @($PesterPath)) {
    $index++
    $candidate = if ([IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $resolvedWorkspace $path }
    $resolvedPath = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    $output = @(& $pesterCommand $resolvedPath -PassThru)
    $result = @($output | Where-Object {
        $_ -and $_.PSObject.Properties['PassedCount'] -and $_.PSObject.Properties['FailedCount'] -and $_.PSObject.Properties['TotalCount']
    }) | Select-Object -Last 1
    if (-not $result) { throw "Invoke-Pester did not return count evidence for '$path'." }
    $passedCount = [int]$result.PassedCount
    $failedCount = [int]$result.FailedCount
    $totalCount = [int]$result.TotalCount
    $skippedCount = if ($result.PSObject.Properties['SkippedCount']) { [int]$result.SkippedCount } else { 0 }
    $evidenceId = "pester-$index"
    $pesterResults.Add([ordered]@{
        evidenceId = $evidenceId
        path = [string]$path
        command = "Invoke-Pester '$path' -PassThru"
        passedCount = $passedCount
        failedCount = $failedCount
        skippedCount = $skippedCount
        totalCount = $totalCount
        result = if ($failedCount -eq 0) { "passed $passedCount/$totalCount" } else { "failed $passedCount/$totalCount" }
    })
}

$evidencePath = Join-Path $taskRoot 'developer-publication-evidence.json'
$evidence = [ordered]@{
    taskId = $TaskId
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    workspace = $resolvedWorkspace
    branch = $branch
    upstream = $upstream
    headCommit = $headCommit
    worktreeClean = ($statusLines.Count -eq 0)
    branchDivergence = [ordered]@{
        evidenceId = 'git-task-base-divergence'
        baseRef = "manifest-baseSha:$taskBaseCommit"
        command = "git rev-list --left-right --count $taskBaseCommit...HEAD"
        behindCount = $taskBehindCount
        aheadCount = $taskAheadCount
        rawResult = $taskDivergenceText
    }
    upstreamDivergence = [ordered]@{
        evidenceId = 'git-upstream-divergence'
        command = "git rev-list --left-right --count $upstream...HEAD"
        behindCount = $upstreamBehindCount
        aheadCount = $upstreamAheadCount
        rawResult = $upstreamDivergenceText
    }
    pester = @($pesterResults)
}
Write-Utf8NoBom -Path $evidencePath -Content (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

$failedPester = @($pesterResults | Where-Object { [int]$_.failedCount -ne 0 })
if ($failedPester.Count) { throw "Final Pester verification failed for: $(@($failedPester.path) -join ', ')" }

[pscustomobject]@{
    TaskId = $TaskId
    EvidencePath = $evidencePath
    Branch = $branch
    HeadCommit = $headCommit
    BehindCount = $taskBehindCount
    AheadCount = $taskAheadCount
    WorktreeClean = ($statusLines.Count -eq 0)
    Pester = @($pesterResults)
}
