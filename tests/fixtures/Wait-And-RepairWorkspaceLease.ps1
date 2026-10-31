[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $GateName,
    [Parameter(Mandatory)][string] $RepairScript,
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][string] $ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$gate = [Threading.EventWaitHandle]::OpenExisting($GateName)
try {
    if (-not $gate.WaitOne([TimeSpan]::FromSeconds(20))) { throw 'Timed out waiting for deterministic repair race gate.' }
    & $RepairScript -TaskId $TaskId -ConfigPath $ConfigPath
}
finally { $gate.Dispose() }
