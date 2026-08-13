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
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

try {
    $hostLock = [IO.File]::Open($hostLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch [IO.IOException] {
    return [pscustomobject]@{ Status='already-running'; HostLockPath=$hostLockPath }
}

try {
    $intervalMinutes = [int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes
    while ($true) {
        try {
            $parameters = @{ Repair=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
            if ($ElevatedApproved -or [bool]$config.workflow.automaticContinuation.useElevatedExecution) { $parameters.ElevatedApproved=$true }
            & (Join-Path $PSScriptRoot 'Repair-AgentContinuations.ps1') @parameters | Out-Null

            # Reload the canonical JSON after every pass so interval and policy
            # changes do not require restarting this resident host.
            $config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
            $intervalMinutes = [int]$config.workflow.automaticContinuation.recoveryPollIntervalMinutes
        }
        catch {
            $record = [ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                type = 'continuation-recovery-host-error'
                message = $_.Exception.Message
            } | ConvertTo-Json -Compress
            [IO.File]::AppendAllText($hostLogPath, $record + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        }

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
