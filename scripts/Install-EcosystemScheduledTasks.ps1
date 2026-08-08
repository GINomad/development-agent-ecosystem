[CmdletBinding()]
param(
    [ValidateSet('Preview','Install','Rollback')][string] $Action = 'Preview',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$sync = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
$wrapper = Join-Path $PSScriptRoot 'Invoke-EnhancedReview.ps1'
$monitorRoot = Resolve-EcosystemPath -Value ([string]$config.review.monitorSkillRoot) -Config $config -CodexHome $CodexHome
$dashboard = Join-Path $monitorRoot 'scripts\open_review_dashboard.ps1'
$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$quote = [string][char]34
$newNames = @(
    'Development Ecosystem - PR Review Updates',
    'Development Ecosystem - PR Review Daily',
    'Development Ecosystem - PR Review Dashboard'
)
$legacyNames = @(
    'Codex PR Review - Updates',
    'Codex PR Review - Daily',
    'Codex PR Review - Dashboard'
)

$specification = [pscustomobject]@{
    Action = $Action
    NewTasks = $newNames
    LegacyTasks = @($legacyNames | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue })
    PollIntervalMinutes = [int]$config.operation.automate.pollIntervalMinutes
    DailyTime = [string]$config.operation.automate.dailyTime
    Wrapper = $wrapper
    ReviewDataRoot = $sync.DataRoot
}
if ($Action -eq 'Preview') { return $specification }

if ($Action -eq 'Rollback') {
    foreach ($name in $newNames) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Disable-ScheduledTask -TaskName $name | Out-Null }
    }
    foreach ($name in $legacyNames) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Enable-ScheduledTask -TaskName $name | Out-Null }
    }
    return [pscustomobject]@{ RolledBack=$true; EnabledLegacyTasks=@($legacyNames); DisabledNewTasks=@($newNames) }
}

& $wrapper -Mode Manual -DryRun -ConfigPath $ConfigPath -CodexHome $CodexHome

$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$pollArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quote$wrapper$quote -Mode Poll -ConfigPath $quote$ConfigPath$quote"
$dailyArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quote$wrapper$quote -Mode Daily -ConfigPath $quote$ConfigPath$quote"
$dashboardArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quote$dashboard$quote -Server -NoBrowser -DataRoot $quote$($sync.DataRoot)$quote"
$pollAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $pollArguments
$dailyAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $dailyArguments
$dashboardAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $dashboardArguments
$pollTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$config.operation.automate.pollIntervalMinutes))
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([string]$config.operation.automate.dailyTime)
$dashboardTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$dashboardSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

$backupRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) 'scheduled-task-backup'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
foreach ($name in $legacyNames) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        $safeName = $name -replace '[^A-Za-z0-9.-]', '-'
        Write-Utf8NoBom -Path (Join-Path $backupRoot "$safeName.xml") -Content (Export-ScheduledTask -TaskName $name)
    }
}

$legacyDisabled = [Collections.Generic.List[string]]::new()
try {
    Register-ScheduledTask -TaskName $newNames[0] -Action $pollAction -Trigger $pollTrigger -Settings $settings -Principal $principal -Description 'Checks active assigned PRs and reruns review when code or comments change.' -Force | Out-Null
    Register-ScheduledTask -TaskName $newNames[1] -Action $dailyAction -Trigger $dailyTrigger -Settings $settings -Principal $principal -Description 'Runs the vendored ecosystem PR review monitor daily.' -Force | Out-Null
    Register-ScheduledTask -TaskName $newNames[2] -Action $dashboardAction -Trigger $dashboardTrigger -Settings $dashboardSettings -Principal $principal -Description 'Serves vendored ecosystem review reports on loopback.' -Force | Out-Null
    foreach ($name in $newNames) {
        if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { throw "New scheduled task '$name' was not registered." }
    }
    foreach ($name in $legacyNames) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Disable-ScheduledTask -TaskName $name | Out-Null
            $legacyDisabled.Add($name)
        }
    }
    Start-ScheduledTask -TaskName $newNames[2]
}
catch {
    foreach ($name in $legacyDisabled) { Enable-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue | Out-Null }
    throw
}

[pscustomobject]@{
    Installed = $true
    NewTasks = $newNames
    DisabledLegacyTasks = @($legacyDisabled)
    RollbackBackupRoot = $backupRoot
    ReviewDataRoot = $sync.DataRoot
}
