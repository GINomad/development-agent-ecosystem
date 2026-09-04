[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskId,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $LeaseId,
    [Parameter(Mandatory)][string] $ConfigPath,
    [AllowEmptyString()][string] $CodexHome
)

[pscustomobject]@{
    TaskId = $TaskId
    RunId = $RunId
    LeaseId = $LeaseId
    ConfigPath = $ConfigPath
    CodexHome = $CodexHome
}
