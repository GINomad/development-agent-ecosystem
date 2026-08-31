[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Prompt,
    [Parameter(Mandatory)][string] $WorkingDirectory,
    [Parameter(Mandatory)][string] $LogPath,
    [Parameter(Mandatory)][string] $GuardArtifactPath,
    [bool] $CapacityFallbackEnabled = $false,
    [string] $FallbackModel,
    [string] $FallbackReasoningEffort,
    [ValidateRange(0,1)][int] $MaxCapacityFallbackAttempts = 1,
    [ValidateRange(1,10)][int] $MaxIdenticalFailures = 3,
    [ValidateRange(1,1440)][int] $MaxRunMinutes = 120,
    [ValidateRange(100,5000)][int] $PollMilliseconds = 500,
    [scriptblock] $HeartbeatAction,
    [ValidateRange(5,300)][int] $HeartbeatIntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Attempt {
    param([string[]] $AttemptArguments, [string] $AttemptGuardPath)
    $attemptParameters = @{
        FilePath = $FilePath
        Arguments = $AttemptArguments
        Prompt = $Prompt
        WorkingDirectory = $WorkingDirectory
        LogPath = $LogPath
        GuardArtifactPath = $AttemptGuardPath
        MaxIdenticalFailures = $MaxIdenticalFailures
        MaxRunMinutes = $MaxRunMinutes
        PollMilliseconds = $PollMilliseconds
        HeartbeatIntervalSeconds = $HeartbeatIntervalSeconds
    }
    if ($HeartbeatAction) { $attemptParameters.HeartbeatAction = $HeartbeatAction }
    & (Join-Path $PSScriptRoot 'Invoke-GuardedCodex.ps1') @attemptParameters
}

$primaryGuardPath = $GuardArtifactPath + '.primary.json'
$primaryResult = Invoke-Attempt -AttemptArguments $Arguments -AttemptGuardPath $primaryGuardPath
$fallbackAttempted = $false
$finalResult = $primaryResult
$fallbackGuardPath = $null
$canFallback = $CapacityFallbackEnabled -and $MaxCapacityFallbackAttempts -eq 1 -and [int]$primaryResult.exitCode -ne 0 -and [string]$primaryResult.failureKind -eq 'model-capacity'
if ($canFallback) {
    if ([string]::IsNullOrWhiteSpace($FallbackModel) -or [string]::IsNullOrWhiteSpace($FallbackReasoningEffort)) {
        throw 'Capacity fallback configuration is incomplete.'
    }
    $fallbackAttempted = $true
    $fallbackArguments = @($Arguments)
    $modelIndex = [array]::IndexOf($fallbackArguments, '--model')
    if ($modelIndex -lt 0) { throw 'Primary --model argument is required.' }
    $fallbackArguments[$modelIndex + 1] = $FallbackModel
    $reasoningIndex = [array]::FindIndex($fallbackArguments, [Predicate[object]]{ param($value) [string]$value -like 'model_reasoning_effort=*' })
    if ($reasoningIndex -lt 0) { throw 'Primary reasoning effort is required.' }
    $fallbackArguments[$reasoningIndex] = 'model_reasoning_effort=' + $FallbackReasoningEffort
    $fallbackGuardPath = $GuardArtifactPath + '.capacity-fallback.json'
    $finalResult = Invoke-Attempt -AttemptArguments $fallbackArguments -AttemptGuardPath $fallbackGuardPath
}

$aggregate = [ordered]@{}
foreach ($property in $finalResult.PSObject.Properties) { $aggregate[$property.Name] = $property.Value }
$aggregate.capacityFallbackAttempted = $fallbackAttempted
$aggregate.capacityFallbackModel = if ($fallbackAttempted) { $FallbackModel } else { $null }
$aggregate.capacityFallbackReasoningEffort = if ($fallbackAttempted) { $FallbackReasoningEffort } else { $null }
$aggregate.primaryGuardPath = $primaryGuardPath
$aggregate.fallbackGuardPath = $fallbackGuardPath
[IO.File]::WriteAllText($GuardArtifactPath, (($aggregate | ConvertTo-Json -Depth 12) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]$aggregate
