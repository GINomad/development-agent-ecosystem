[CmdletBinding()]
param(
    [switch] $ElevatedApproved,
    [switch] $RunOnce,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$hostLockPath = Join-Path $stateRoot 'continuation-recovery-host.lock'
$hostLogPath = Join-Path $stateRoot 'continuation-recovery-host.jsonl'
$healthRoot = Join-Path $stateRoot 'health'
$resultPath = Join-Path $healthRoot 'continuation-recovery-result.json'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
New-Item -ItemType Directory -Path $healthRoot -Force | Out-Null
$cycleErrors = [Collections.Generic.List[object]]::new()

function Write-RecoveryHostError {
    param(
        [Parameter(Mandatory)][string] $Component,
        [Parameter(Mandatory)][Management.Automation.ErrorRecord] $ErrorRecord
    )

    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        type = 'continuation-recovery-host-error'
        component = $Component
        message = $ErrorRecord.Exception.Message
    } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($hostLogPath, $record + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $cycleErrors.Add([pscustomobject]@{ component=$Component; message=$ErrorRecord.Exception.Message })
}

function Write-RecoveryHostResult {
    param([string]$ContinuationRepairStatus,[string]$WorkspaceCleanupStatus)
    $result = [ordered]@{
        schemaVersion = '1.0.0'
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = if ($cycleErrors.Count) { 'degraded' } else { 'healthy' }
        continuationRepairStatus = $ContinuationRepairStatus
        workspaceCleanupStatus = $WorkspaceCleanupStatus
        errors = @($cycleErrors)
    }
    Write-Utf8NoBomAtomic -Path $resultPath -Content (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

try {
    $hostLock = [IO.File]::Open($hostLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch [IO.IOException] {
    return [pscustomobject]@{ Status='already-running'; HostLockPath=$hostLockPath }
}

try {
    $intervalMinutes = [int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes
    while ($true) {
        $cycleErrors.Clear()
        $continuationRepairStatus = 'completed'
        $workspaceCleanupStatus = 'completed'
        try {
            $parameters = @{ Repair=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved -or [bool]$config.workflow.automaticContinuation.useElevatedExecution) { $parameters.ElevatedApproved=$true }
            & (Join-Path $PSScriptRoot 'Repair-AgentContinuations.ps1') @parameters | Out-Null
        }
        catch {
            $continuationRepairStatus = 'failed'
            Write-RecoveryHostError -Component 'continuation-repair' -ErrorRecord $_
        }

        try {
            & (Join-Path $PSScriptRoot 'Remove-CompletedTaskWorkspaces.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
        }
        catch {
            $workspaceCleanupStatus = 'failed'
            Write-RecoveryHostError -Component 'workspace-cleanup' -ErrorRecord $_
        }

        try {
            # Reload the canonical JSON after every pass so interval and policy
            # changes do not require restarting this resident host.
            $config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
            $intervalMinutes = [int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes
        }
        catch {
            Write-RecoveryHostError -Component 'config-reload' -ErrorRecord $_
        }
        Write-RecoveryHostResult -ContinuationRepairStatus $continuationRepairStatus -WorkspaceCleanupStatus $workspaceCleanupStatus

        if ($RunOnce) { break }
        $remainingSeconds = [Math]::Max(1, $intervalMinutes * 60)
        while ($remainingSeconds -gt 0) {
            $sleepSeconds = [Math]::Min(60, $remainingSeconds)
            Start-Sleep -Seconds $sleepSeconds
            $remainingSeconds -= $sleepSeconds
        }
    }
}
finally {
    $hostLock.Dispose()
}

[pscustomobject]@{ Status='completed'; HostLockPath=$hostLockPath; RunOnce=[bool]$RunOnce }
