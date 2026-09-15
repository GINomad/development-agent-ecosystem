[CmdletBinding()]
param(
    [ValidateRange(5, 1440)][int] $PollIntervalMinutes = 60,
    [ValidatePattern('^\d{2}:\d{2}$')][string] $DailyTime = '11:00'
)

$ErrorActionPreference = 'Stop'
$runnerPath = Join-Path $PSScriptRoot 'run_pr_review_monitor.ps1'
$dashboardPath = Join-Path $PSScriptRoot 'open_review_dashboard.ps1'
if (-not (Test-Path $runnerPath)) { throw "Runner was not found at $runnerPath." }
if (-not (Test-Path $dashboardPath)) { throw "Dashboard was not found at $dashboardPath." }
$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)

foreach ($legacyName in @('Codex Azure PR Review - Updates','Codex Azure PR Review - Daily','Codex Azure PR Review - Dashboard')) {
    if (Get-ScheduledTask -TaskName $legacyName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $legacyName -Confirm:$false }
}

$pollAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`" -Mode Poll"
$pollTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $PollIntervalMinutes)
Register-ScheduledTask -TaskName 'Codex PR Review - Updates' -Action $pollAction -Trigger $pollTrigger -Settings $settings -Principal $principal -Description 'Checks configured Azure DevOps and GitHub repositories for changed assigned PRs.' -Force | Out-Null

$dailyAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`" -Mode Daily"
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
Register-ScheduledTask -TaskName 'Codex PR Review - Daily' -Action $dailyAction -Trigger $dailyTrigger -Settings $settings -Principal $principal -Description 'Runs the guarded multi-provider PR review check every day.' -Force | Out-Null

$dashboardSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$dashboardAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dashboardPath`" -Server -NoBrowser"
$dashboardTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
Register-ScheduledTask -TaskName 'Codex PR Review - Dashboard' -Action $dashboardAction -Trigger $dashboardTrigger -Settings $dashboardSettings -Principal $principal -Description 'Serves interactive PR review reports only on the local loopback interface.' -Force | Out-Null
& $dashboardPath -NoBrowser | Out-Null
Write-Output 'Installed scheduled tasks: Codex PR Review - Updates, Daily, Dashboard.'
