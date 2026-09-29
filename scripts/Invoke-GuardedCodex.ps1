[CmdletBinding()]
param(
    [ValidateSet('codex','claude')][string] $Provider = 'codex',
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter(Mandatory)][string[]] $Arguments,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Prompt,
    [Parameter(Mandatory)][string] $WorkingDirectory,
    [Parameter(Mandatory)][string] $LogPath,
    [Parameter(Mandatory)][string] $GuardArtifactPath,
    [ValidateRange(1,10)][int] $MaxIdenticalFailures = 3,
    [ValidateRange(1,1440)][int] $MaxRunMinutes = 120,
    [ValidateRange(100,5000)][int] $PollMilliseconds = 500,
    [scriptblock] $HeartbeatAction,
    [ValidateRange(5,300)][int] $HeartbeatIntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string] $Value)
    if ($Value.Length -and $Value -notmatch '\s' -and -not $Value.Contains([char]34)) { return $Value }
    $quote = [string][char]34
    return $quote + $Value.Replace($quote, ('\' + $quote)) + $quote
}

function Get-FailureFingerprint {
    param([string] $Line)
    try { $event = $Line | ConvertFrom-Json } catch {
        if ($Line -notmatch '(?i)quota|rate[- ]?limit|limit reached|capacity|too many requests|authentication|unauthorized|not logged') { return $null }
        $canonical = (($Line -replace '\s+', ' ').Trim())
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        return [pscustomobject]@{ Signature=$signature; Canonical=$canonical; Detail=$Line; Kind='provider-failure' }
    }
    if ($Provider -eq 'claude' -and [string]$event.type -eq 'result' -and $event.PSObject.Properties['is_error'] -and [bool]$event.is_error) {
        $detail = if ($event.PSObject.Properties['result']) { [string]$event.result } else { ($event | ConvertTo-Json -Depth 12 -Compress) }
        $canonical = (($detail -replace '\s+', ' ').Trim())
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        return [pscustomobject]@{ Signature=$signature; Canonical=$canonical; Detail=$detail; Kind='provider-failure' }
    }
    if ([string]$event.type -eq 'error' -and $event.PSObject.Properties['message']) {
        $detail = [string]$event.message
        if ($detail -match '(?i)selected model is at capacity') {
            $canonical = 'model-capacity'
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            return [pscustomobject]@{ Signature=$signature; Canonical=$canonical; Detail=$detail; Kind='model-capacity' }
        }
        return $null
    }
    if ([string]$event.type -ne 'item.completed' -or -not $event.PSObject.Properties['item']) { return $null }
    $item = $event.item
    if (-not $item.PSObject.Properties['status']) { return $null }
    if ([string]$item.status -ne 'failed') { return $null }
    $detail = if ($item.PSObject.Properties['aggregated_output']) { [string]$item.aggregated_output } elseif ($item.PSObject.Properties['error']) { [string]$item.error } else { ($item | ConvertTo-Json -Depth 12 -Compress) }
    if ([string]::IsNullOrWhiteSpace($detail)) { return $null }
    $hasPowerShellParserDiagnostic = $detail -match '(?m)^\s*ParserError\s*:\s*(?:[^\r\n]*\r?\n)?\s*(?:Line\s*\||\d+\s*\|)'
    $hasPowerShellReadonlyPidDiagnostic = $detail -match '(?m)^\s*(?:ParserError|WriteError)\s*:\s*(?:[^\r\n]*\r?\n){0,4}[^\r\n]*\bCannot overwrite variable PID\b'
    $kind = if ($hasPowerShellParserDiagnostic) { 'command-parse-failure' } else { 'execution-failure' }
    $canonical = if ($detail -match 'CreateProcessWithLogonW failed:\s*1260') { 'windows-sandbox-create-process-1260' } elseif ($hasPowerShellReadonlyPidDiagnostic) { 'powershell-readonly-pid' } else { (($detail -replace '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', '<timestamp>') -replace '\s+', ' ').Trim() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    [pscustomobject]@{ Signature=$signature; Canonical=$canonical; Detail=$detail; Kind=$kind }
}

function Remove-TemporaryFileWithRetry {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1,50)][int] $MaxAttempts = 20,
        [ValidateRange(10,1000)][int] $DelayMilliseconds = 100
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Warning ("Temporary runner file remains locked after {0} attempts: {1}. {2}" -f $MaxAttempts,$Path,$_.Exception.Message)
                return
            }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

$encoding = New-Object Text.UTF8Encoding($false)
$runId = [guid]::NewGuid().ToString('N')
$promptPath = $LogPath + '.' + $runId + '.stdin.txt'
$stdoutPath = $LogPath + '.' + $runId + '.stdout.tmp'
$stderrPath = $LogPath + '.' + $runId + '.stderr.log'
[IO.File]::WriteAllText($promptPath, $Prompt, $encoding)
foreach ($temporaryPath in @($stdoutPath,$stderrPath)) {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
$argumentLine = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) }) -join ' ')
$process = Start-Process -FilePath $FilePath -ArgumentList $argumentLine -WorkingDirectory $WorkingDirectory -RedirectStandardInput $promptPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -PassThru
$process = Get-Process -Id $process.Id -ErrorAction Stop
$processId = $process.Id
$startedAtUtc = [DateTime]::UtcNow
$lastHeartbeatAtUtc = $startedAtUtc
$lineIndex = 0
$lastFailureSignature = $null
$identicalFailureCount = 0
$guardTriggered = $false
$guardReason = $null
$lastFailure = $null
$monitorCompleted = $false
$nativeExitCode = $null

try {
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds $PollMilliseconds
        if ($HeartbeatAction -and ([DateTime]::UtcNow - $lastHeartbeatAtUtc).TotalSeconds -ge $HeartbeatIntervalSeconds) {
            & $HeartbeatAction | Out-Null
            $lastHeartbeatAtUtc = [DateTime]::UtcNow
        }
        [array]$lines = @()
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [array]$lines = @(Get-Content -LiteralPath $stdoutPath -Encoding UTF8) }
        while ($lineIndex -lt $lines.Count) {
            $line = [string]$lines[$lineIndex++]
            [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $encoding)
            $failure = Get-FailureFingerprint -Line $line
            if ($failure) {
                if ($failure.Signature -eq $lastFailureSignature) { $identicalFailureCount++ } else { $lastFailureSignature = $failure.Signature; $identicalFailureCount = 1 }
                $lastFailure = $failure
                if ($failure.Kind -in @('command-parse-failure','provider-failure') -or $identicalFailureCount -ge $MaxIdenticalFailures) {
                    $guardTriggered = $true
                    $guardReason = if ($failure.Kind -eq 'command-parse-failure') { 'Non-retryable command parse failure: {0}' -f $failure.Canonical } elseif ($failure.Kind -eq 'provider-failure') { 'Provider failure: {0}' -f $failure.Canonical } else { 'Execution retry limit reached after {0} identical failures: {1}' -f $identicalFailureCount,$failure.Canonical }
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    break
                }
            }
        }
        if (-not $guardTriggered -and ([DateTime]::UtcNow - $startedAtUtc).TotalMinutes -ge $MaxRunMinutes) {
            $guardTriggered = $true
            $guardReason = 'Workflow execution timeout reached after {0} minutes.' -f $MaxRunMinutes
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        $process.Refresh()
    }
    $process.WaitForExit()
    $process.Refresh()
    $nativeExitCode = $process.ExitCode
    $monitorCompleted = $true
}
finally {
    if (-not $monitorCompleted -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        try { $process.WaitForExit() } catch { }
    }
    [array]$remainingLines = @()
    if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [array]$remainingLines = @(Get-Content -LiteralPath $stdoutPath -Encoding UTF8) }
    while ($lineIndex -lt $remainingLines.Count) {
        $line = [string]$remainingLines[$lineIndex++]
        [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $encoding)
        $failure = Get-FailureFingerprint -Line $line
        if ($failure) {
            if ($failure.Signature -eq $lastFailureSignature) { $identicalFailureCount++ } else { $lastFailureSignature = $failure.Signature; $identicalFailureCount = 1 }
            $lastFailure = $failure
            if ($failure.Kind -in @('command-parse-failure','provider-failure') -or $identicalFailureCount -ge $MaxIdenticalFailures) {
                $guardTriggered = $true
                $guardReason = if ($failure.Kind -eq 'command-parse-failure') { 'Non-retryable command parse failure: {0}' -f $failure.Canonical } elseif ($failure.Kind -eq 'provider-failure') { 'Provider failure: {0}' -f $failure.Canonical } else { 'Execution retry limit reached after {0} identical failures: {1}' -f $identicalFailureCount,$failure.Canonical }
            }
        }
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        foreach ($stderrLine in @(Get-Content -LiteralPath $stderrPath -Encoding UTF8)) {
            $record = [ordered]@{ type=($Provider + '-stderr'); provider=$Provider; text=[string]$stderrLine } | ConvertTo-Json -Compress
            [IO.File]::AppendAllText($LogPath, $record + [Environment]::NewLine, $encoding)
        }
    }
}

$completedTurn = $false
if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
    foreach ($outputLine in @(Get-Content -LiteralPath $stdoutPath -Encoding UTF8)) {
        try {
            $outputEvent = $outputLine | ConvertFrom-Json
            if ([string]$outputEvent.type -eq 'turn.completed') { $completedTurn = $true; break }
        }
        catch { }
    }
}
$resolvedExitCode = if ($null -ne $nativeExitCode) { [int]$nativeExitCode } elseif ($completedTurn) { 0 } else { 1 }

$result = [ordered]@{
    guardTriggered = $guardTriggered
    reason = $guardReason
    maxIdenticalFailures = $MaxIdenticalFailures
    identicalFailureCount = $identicalFailureCount
    failureSignature = if ($lastFailure) { $lastFailure.Signature } else { $null }
    failureCanonical = if ($lastFailure) { $lastFailure.Canonical } else { $null }
    failureDetail = if ($lastFailure) { $lastFailure.Detail } else { $null }
    failureKind = if ($lastFailure) { $lastFailure.Kind } else { $null }
    maxRunMinutes = $MaxRunMinutes
    startedAtUtc = $startedAtUtc.ToString('o')
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    processId = $processId
    exitCode = $resolvedExitCode
    provider = $Provider
    exitCodeSource = if ($null -ne $nativeExitCode) { 'native' } else { $Provider + '-event-fallback' }
    logPath = $LogPath
    stderrPath = $stderrPath
}
[IO.File]::WriteAllText($GuardArtifactPath, (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $encoding)
$process.Dispose()
foreach ($temporaryPath in @($promptPath,$stdoutPath)) {
    Remove-TemporaryFileWithRetry -Path $temporaryPath
}
[pscustomobject]$result
