[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $LeaseId,
    [Parameter(Mandatory)][string] $ConfigPath,
    [AllowEmptyString()][string] $CodexHome
)

switch ($TaskId) {
    'heartbeat-lock-contention' {
        throw [IO.IOException]::new("Timed out waiting for exclusive lock 'C:\synthetic\workspace-coordinator.json.lock'.")
    }
    'heartbeat-ownership-failure' {
        throw [InvalidOperationException]::new('Synthetic workspace lease is no longer owned.')
    }
    'heartbeat-io-failure' {
        throw [IO.IOException]::new('Synthetic unrelated I/O failure.')
    }
    default {
        throw [InvalidOperationException]::new("Unexpected synthetic heartbeat task '$TaskId'.")
    }
}
