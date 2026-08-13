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
$prLifecycle = Join-Path $PSScriptRoot 'Sync-ActiveTaskPullRequests.ps1'
$continuationRecoveryHost = Join-Path $PSScriptRoot 'Start-AgentContinuationRecoveryHost.ps1'
$weeklyKnowledgeReport = Join-Path $PSScriptRoot 'New-WeeklyKnowledgeReport.ps1'
$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$quote = [string][char]34
$newNames = @(
    'Development Ecosystem - PR Review Updates',
    'Development Ecosystem - PR Review Daily',
    'Development Ecosystem - PR Review Dashboard',
    'Development Ecosystem - Task PR Lifecycle',
    'Development Ecosystem - Continuation Recovery',
    'Development Ecosystem - Knowledge Weekly Report'
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
    PullRequestLifecycleIntervalMinutes = [int]$config.pipeline.pullRequests.pollIntervalMinutes
    ContinuationRecoveryIntervalMinutes = [int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes
    KnowledgeWeeklyReport = [pscustomobject]@{ Enabled=[bool]$config.knowledge.weeklyReport.enabled; DayOfWeek=[string]$config.knowledge.weeklyReport.dayOfWeek; LocalTime=[string]$config.knowledge.weeklyReport.localTime; OutputRoot=[string]$config.knowledge.weeklyReport.outputRoot }
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
$nonInteractivePrincipal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$backgroundPowerShellArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass'
$pollArguments = "$backgroundPowerShellArguments -File $quote$wrapper$quote -Mode Poll -ConfigPath $quote$ConfigPath$quote"
$dailyArguments = "$backgroundPowerShellArguments -File $quote$wrapper$quote -Mode Daily -ConfigPath $quote$ConfigPath$quote"
$dashboardArguments = "$backgroundPowerShellArguments -File $quote$dashboard$quote -Server -NoBrowser -DataRoot $quote$($sync.DataRoot)$quote"
$prLifecycleArguments = "$backgroundPowerShellArguments -File $quote$prLifecycle$quote -ConfigPath $quote$ConfigPath$quote"
$continuationArguments = "$backgroundPowerShellArguments -File $quote$continuationRecoveryHost$quote -RunOnce -ElevatedApproved -ConfigPath $quote$ConfigPath$quote"
$weeklyKnowledgeArguments = "$backgroundPowerShellArguments -File $quote$weeklyKnowledgeReport$quote -ConfigPath $quote$ConfigPath$quote"
$pollAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $pollArguments
$dailyAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $dailyArguments
$dashboardAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $dashboardArguments
$prLifecycleAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $prLifecycleArguments
$continuationAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $continuationArguments
$weeklyKnowledgeAction = New-ScheduledTaskAction -Execute $powerShellPath -Argument $weeklyKnowledgeArguments
$pollTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$config.operation.automate.pollIntervalMinutes))
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ([string]$config.operation.automate.dailyTime)
$dashboardTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$prLifecycleTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$config.pipeline.pullRequests.pollIntervalMinutes))
$continuationTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes))
$weeklyKnowledgeDay = [Enum]::Parse([DayOfWeek], [string]$config.knowledge.weeklyReport.dayOfWeek, $true)
$weeklyKnowledgeAt = [DateTime]::ParseExact([string]$config.knowledge.weeklyReport.localTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$weeklyKnowledgeTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weeklyKnowledgeDay -At $weeklyKnowledgeAt
$dashboardSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$continuationSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

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
    Register-ScheduledTask -TaskName $newNames[3] -Action $prLifecycleAction -Trigger $prLifecycleTrigger -Settings $settings -Principal $principal -Description 'Synchronizes task PR status without AI polling and routes completed PR tasks through Orchestrator for final Knowledge Keeper publication.' -Force | Out-Null
    Register-ScheduledTask -TaskName $newNames[4] -Action $continuationAction -Trigger $continuationTrigger -Settings $continuationSettings -Principal $principal -Description 'Runs a bounded hidden recovery pass on the configured interval so a terminated host cannot permanently lose a durable agent handoff.' -Force | Out-Null
    Register-ScheduledTask -TaskName $newNames[5] -Action $weeklyKnowledgeAction -Trigger $weeklyKnowledgeTrigger -Settings $settings -Principal $nonInteractivePrincipal -Description 'Generates a Friday HTML report from verified Knowledge Keeper learning, decisions, and durable evidence without invoking AI.' -Force | Out-Null
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
    Start-ScheduledTask -TaskName $newNames[4]
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
