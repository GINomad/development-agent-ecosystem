[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][string] $Stage,
    [Parameter(Mandatory)][string] $Summary,
    [Nullable[int]] $ExitCode,
    [string] $Diagnostic,
    [ValidatePattern('^[A-Za-z0-9._-]{8,128}$')][string] $CorrelationId,
    [string[]] $Evidence = @(),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskRoot = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId"
if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$normalizedDiagnostic = if ($Diagnostic) { $Diagnostic.Trim() } else { '' }
$normalized = "$AgentId|$Stage|$($Summary.Trim())|$normalizedDiagnostic"
$sha = [Security.Cryptography.SHA256]::Create()
try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
$failureId = [guid]::NewGuid().ToString('N')
$occurrenceId = [guid]::NewGuid().ToString('N')
$rootCauseText = (($Summary.Trim() + ' ' + $normalizedDiagnostic) -replace '(?i)Execution retry limit reached after \d+ identical failures:\s*','' -replace '(?i)Non-retryable command parse failure:\s*','' -replace '[0-9a-f]{32,64}','<id>' -replace '\b\d+\b','<n>' -replace '\s+',' ').Trim().ToLowerInvariant()
$rootCauseSha = [Security.Cryptography.SHA256]::Create()
try { $rootCauseFingerprint = ([BitConverter]::ToString($rootCauseSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($rootCauseText)))).Replace('-','').ToLowerInvariant() } finally { $rootCauseSha.Dispose() }
if (-not $CorrelationId) { $CorrelationId = "cause-$($rootCauseFingerprint.Substring(0,24))" }
$occurredAtUtc = [DateTime]::UtcNow.ToString('o')
$failure = [ordered]@{
    failureId = $failureId
    occurrenceId = $occurrenceId
    correlationId = $CorrelationId
    failureSignature = $signature
    rootCauseFingerprint = $rootCauseFingerprint
    taskId = $TaskId
    agentId = $AgentId
    stage = $Stage
    occurredAtUtc = $occurredAtUtc
    summary = $Summary.Trim()
    exitCode = if ($null -ne $ExitCode) { [int]$ExitCode } else { $null }
    diagnostic = if ($Diagnostic) { $Diagnostic.Trim() } else { $null }
    evidence = @($Evidence | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$failurePath = Join-Path $taskRoot "agent-failure-$($occurredAtUtc.Replace(':','').Replace('-','').Replace('.',''))-$failureId.json"
Write-Utf8NoBom -Path $failurePath -Content (($failure | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
& (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type agent-failure -Summary ([string]$failure.summary) -Artifact $failurePath -Evidence @($failure.evidence) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -AgentId $AgentId -AgentStatus failed -Stage $Stage -Message ([string]$failure.summary) -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
[pscustomobject]@{ FailurePath=$failurePath; Failure=[pscustomobject]$failure }
