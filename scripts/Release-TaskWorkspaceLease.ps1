[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [string] $LeaseId,
    [string] $Reason = 'released',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
$coordinatorPath = Resolve-EcosystemPath -Value ([string]$config.workflow.workspaceScheduling.coordinatorStatePath) -Config $config -CodexHome $CodexHome
$releasedLease = Invoke-EcosystemFileLock -LockPath "$coordinatorPath.lock" -TimeoutSeconds ([int]$config.workflow.workspaceScheduling.lockTimeoutSeconds) -Action {
    $coordinator = if (Test-Path -LiteralPath $coordinatorPath -PathType Leaf) { Get-Content -LiteralPath $coordinatorPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject][ordered]@{ schemaVersion='2.0.0'; leases=@(); updatedAtUtc=$null } }
    $matches = @($coordinator.leases | Where-Object { [string]$_.taskId -eq $TaskId })
    if ($LeaseId) { $matches = @($matches | Where-Object { [string]$_.leaseId -eq $LeaseId }) }
    if ($LeaseId -and -not $matches.Count) { throw "Lease '$LeaseId' is not owned by task '$TaskId'." }
    $coordinator.leases = @($coordinator.leases | Where-Object { [string]$_.taskId -ne $TaskId })
    $coordinator.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-Utf8NoBomAtomic -Path $coordinatorPath -Content (($coordinator | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    return @($matches | Select-Object -First 1)
}
$manifestDirectory = Join-Path $stateRoot "tasks\$TaskId\workspaces"
foreach ($manifestPath in @(Get-ChildItem -LiteralPath $manifestDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($LeaseId -and [string]$manifest.leaseId -ne $LeaseId) { continue }
    $releasedAtUtc = [DateTime]::UtcNow.ToString('o')
    $manifest | Add-Member -NotePropertyName lifecycle -NotePropertyValue 'released' -Force
    $manifest | Add-Member -NotePropertyName releaseReason -NotePropertyValue $Reason -Force
    $manifest | Add-Member -NotePropertyName releasedAtUtc -NotePropertyValue $releasedAtUtc -Force
    $manifest | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $releasedAtUtc -Force
    Write-Utf8NoBomAtomic -Path $manifestPath.FullName -Content (($manifest | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
}
[pscustomobject]@{ Status='released'; TaskId=$TaskId; LeaseId=if ($releasedLease) { [string]$releasedLease.leaseId } else { $LeaseId }; Reason=$Reason }
