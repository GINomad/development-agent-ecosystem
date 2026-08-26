[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Prompt,
    [Parameter(Mandatory)][string] $WorkingDirectory,
    [Parameter(Mandatory)][string] $LogPath,
    [Parameter(Mandatory)][string] $GuardArtifactPath,
    [ValidateRange(1,10)][int] $MaxIdenticalFailures = 3,
    [ValidateRange(1,1440)][int] $MaxRunMinutes = 120,
    [ValidateRange(100,5000)][int] $PollMilliseconds = 500
)

# The execution guard is provider-neutral. Keep the legacy implementation as the
# single process supervision implementation while Codex and Claude share it.
& (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') @PSBoundParameters
