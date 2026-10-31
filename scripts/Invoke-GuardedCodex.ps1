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
    [ValidateRange(1,300)][int] $CompletedTurnExitGraceSeconds = 30,
    [ValidateRange(1,20)][int] $MaxTransportFailures = 3,
    [ValidateRange(1,3600)][int] $TransportNoProgressSeconds = 300,
    [scriptblock] $HeartbeatAction,
    [ValidateRange(5,300)][int] $HeartbeatIntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string] $Value)
    if ($Value.Length -and $Value -notmatch '\s' -and -not $Value.Contains([char]34)) { return $Value }
    $quote = [string][char]34
    return $quote + $Value.Replace($quote, ('\' + $quote)) + $quote
}

function Get-FailureFingerprint {
    param([string] $Line)
    try { $event = $Line | ConvertFrom-Json } catch {
        $classification = & (Join-Path (Get-EcosystemRoot) 'scripts/Get-ProviderFailureClassification.ps1') -Diagnostic $Line
        if ([string]$classification.Category -notin @('provider-limit','provider-authentication')) { return $null }
        $canonical = (($Line -replace '\s+', ' ').Trim())
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        return [pscustomobject]@{ Signature=$signature; Canonical=$canonical; Detail=$Line; Kind='provider-failure' }
    }
    if ($null -eq $event -or $event -isnot [pscustomobject] -or -not $event.PSObject.Properties['type']) { return $null }
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
        $classified = & (Join-Path (Get-EcosystemRoot) 'scripts/Get-ProviderFailureClassification.ps1') -Diagnostic $Line
        if ([string]$classified.Category -in @('provider-limit','provider-authentication')) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $signature = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($detail)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            return [pscustomobject]@{Signature=$signature;Canonical=$detail;Detail=$detail;Kind='provider-failure'}
        }
        return $null
    }
    if ([string]$event.type -ne 'item.completed' -or -not $event.PSObject.Properties['item']) { return $null }
    $item = $event.item
    if ($null -eq $item -or $item -isnot [pscustomobject]) { return $null }
    if (-not $item.PSObject.Properties['status']) { return $null }
    if ([string]$item.status -ne 'failed') { return $null }
    $detail = if ($item.PSObject.Properties['aggregated_output']) { [string]$item.aggregated_output } elseif ($item.PSObject.Properties['error']) { [string]$item.error } else { ($item | ConvertTo-Json -Depth 12 -Compress) }
    if ([string]::IsNullOrWhiteSpace($detail)) { return $null }
    $hasPowerShellParserDiagnostic = $detail -match '(?m)^\s*ParserError\s*:\s*(?:[^\r\n]*\r?\n)?\s*(?:Line\s*\||\d+\s*\|)'
    $hasPowerShellReadonlyPidDiagnostic = $detail -match '(?m)^\s*(?:ParserError|WriteError)\s*:\s*(?:[^\r\n]*\r?\n){0,4}[^\r\n]*\bCannot overwrite variable PID\b'
    $kind = 'execution-failure'
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

function Test-ProviderCompletedEvent {
    param([string] $Line)
    try { $event = $Line | ConvertFrom-Json } catch { return $false }
    if ($null -eq $event -or $event -isnot [pscustomobject] -or -not $event.PSObject.Properties['type']) { return $false }
    if ($Provider -eq 'codex') { return [string]$event.type -eq 'turn.completed' }
    return [string]$event.type -eq 'result' -and
        $event.PSObject.Properties['subtype'] -and [string]$event.subtype -eq 'success' -and
        $event.PSObject.Properties['terminal_reason'] -and [string]$event.terminal_reason -eq 'completed' -and
        (-not $event.PSObject.Properties['is_error'] -or -not [bool]$event.is_error)
}

$encoding = New-Object Text.UTF8Encoding($false)
$runId = [guid]::NewGuid().ToString('N')
$promptPath = $LogPath + '.' + $runId + '.stdin.txt'
$stdoutPath = $LogPath + '.' + $runId + '.stdout.tmp'
$stderrPath = $LogPath + '.' + $runId + '.stderr.log'
$process = $null
try {
[IO.File]::WriteAllText($promptPath, $Prompt, $encoding)
foreach ($temporaryPath in @($stdoutPath,$stderrPath)) {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
$argumentLine = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) }) -join ' ')
$process = Start-Process -FilePath $FilePath -ArgumentList $argumentLine -WorkingDirectory $WorkingDirectory -RedirectStandardInput $promptPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
# PowerShell 5.1 can lose the native handle when a short-lived child exits before
# Process.Handle has ever been requested. Force handle acquisition immediately so
# ExitCode remains available after the process terminates.
$null = $process.Handle
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
$completedTurnAtUtc = $null
$completedTurnExitCleanup = $false
$stderrLineIndex = 0
$transportFailureCount = 0
$firstTransportFailureAtUtc = $null

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
            Add-EcosystemUtf8Line -Path $LogPath -Line $line
            if ($Provider -eq 'codex' -and $null -eq $completedTurnAtUtc -and (Test-ProviderCompletedEvent -Line $line)) {
                $completedTurnAtUtc = [DateTime]::UtcNow
            }
            try {
                $progressEvent = $line | ConvertFrom-Json -ErrorAction Stop
                if ($progressEvent.PSObject.Properties['type'] -and [string]$progressEvent.type -in @('item.started','item.updated','item.completed','turn.completed') -and (-not $progressEvent.PSObject.Properties['item'] -or -not $progressEvent.item.PSObject.Properties['status'] -or [string]$progressEvent.item.status -ne 'failed')) {
                    $transportFailureCount = 0; $firstTransportFailureAtUtc = $null
                }
            } catch { }
            $failure = Get-FailureFingerprint -Line $line
            if ($failure) {
                if ($failure.Signature -eq $lastFailureSignature) { $identicalFailureCount++ } else { $lastFailureSignature = $failure.Signature; $identicalFailureCount = 1 }
                $lastFailure = $failure
                if ($failure.Kind -eq 'provider-failure' -or $identicalFailureCount -ge $MaxIdenticalFailures) {
                    $guardTriggered = $true
                    $guardReason = if ($failure.Kind -eq 'provider-failure') { 'Provider failure: {0}' -f $failure.Canonical } else { 'Execution retry limit reached after {0} identical failures: {1}' -f $identicalFailureCount,$failure.Canonical }
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    break
                }
            }
        }
        if (-not $guardTriggered -and (Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
            $stderrLines = @(Get-Content -LiteralPath $stderrPath -Encoding UTF8)
            while ($stderrLineIndex -lt $stderrLines.Count) {
                $stderrLine = [string]$stderrLines[$stderrLineIndex++]
                $transport = & (Join-Path $PSScriptRoot 'Get-ProviderFailureClassification.ps1') -Diagnostic $stderrLine
                if ([string]$transport.Category -eq 'provider-transport') {
                    $transportFailureCount++
                    Add-EcosystemUtf8Line -Path $LogPath -Line (([ordered]@{type='ecosystem-transport-retry';category='provider-transport';count=$transportFailureCount;timestampUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress))
                    if ($null -eq $firstTransportFailureAtUtc) { $firstTransportFailureAtUtc = [DateTime]::UtcNow }
                }
            }
            if ($null -eq $completedTurnAtUtc -and $null -ne $firstTransportFailureAtUtc -and ($transportFailureCount -ge $MaxTransportFailures -or ([DateTime]::UtcNow - $firstTransportFailureAtUtc).TotalSeconds -ge $TransportNoProgressSeconds)) {
                $guardTriggered = $true
                $guardReason = 'Provider transport unavailable without progress; bounded retry budget exhausted.'
                $lastFailure = [pscustomobject]@{Signature='provider-transport-unavailable';Canonical='provider-transport-unavailable';Detail=$guardReason;Kind='provider-transport'}
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
        # A completed turn can leave the CLI alive during shutdown. Bound only
        # that shutdown wait; task artifact and continuation gates remain with the caller.
        if (-not $guardTriggered -and $null -ne $completedTurnAtUtc -and
            ([DateTime]::UtcNow - $completedTurnAtUtc).TotalSeconds -ge $CompletedTurnExitGraceSeconds -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $completedTurnExitCleanup = $true
        }
        if (-not $guardTriggered -and $null -eq $completedTurnAtUtc -and ([DateTime]::UtcNow - $startedAtUtc).TotalMinutes -ge $MaxRunMinutes) {
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
        Add-EcosystemUtf8Line -Path $LogPath -Line $line
        $failure = Get-FailureFingerprint -Line $line
        if ($failure) {
            if ($failure.Signature -eq $lastFailureSignature) { $identicalFailureCount++ } else { $lastFailureSignature = $failure.Signature; $identicalFailureCount = 1 }
            $lastFailure = $failure
            if ($failure.Kind -eq 'provider-failure' -or $identicalFailureCount -ge $MaxIdenticalFailures) {
                $guardTriggered = $true
                $guardReason = if ($failure.Kind -eq 'provider-failure') { 'Provider failure: {0}' -f $failure.Canonical } else { 'Execution retry limit reached after {0} identical failures: {1}' -f $identicalFailureCount,$failure.Canonical }
            }
        }
    }
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        foreach ($stderrLine in @(Get-Content -LiteralPath $stderrPath -Encoding UTF8)) {
            $record = [ordered]@{ type=($Provider + '-stderr'); provider=$Provider; text=[string]$stderrLine } | ConvertTo-Json -Compress
            Add-EcosystemUtf8Line -Path $LogPath -Line $record
        }
    }
}

$completedProviderRun = $false
if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
    foreach ($outputLine in @(Get-Content -LiteralPath $stdoutPath -Encoding UTF8)) {
        if (Test-ProviderCompletedEvent -Line $outputLine) { $completedProviderRun = $true; break }
    }
}
$semanticSuccessOverride = -not $guardTriggered -and $completedProviderRun -and ($Provider -eq 'claude' -or $completedTurnExitCleanup)
$resolvedExitCode = if ($guardTriggered) { 1 } elseif ($semanticSuccessOverride) { 0 } elseif ($null -ne $nativeExitCode) { [int]$nativeExitCode } elseif ($completedProviderRun) { 0 } else { 1 }

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
    transportFailureCount = $transportFailureCount
    maxTransportFailures = $MaxTransportFailures
    transportNoProgressSeconds = $TransportNoProgressSeconds
    completedTurnExitCleanup = $completedTurnExitCleanup
    completedTurnExitGraceSeconds = $CompletedTurnExitGraceSeconds
    exitCodeSource = if ($semanticSuccessOverride) { $Provider + '-semantic-success-override' } elseif ($null -ne $nativeExitCode) { 'native' } else { $Provider + '-event-fallback' }
    logPath = $LogPath
    stderrPath = $stderrPath
}
[IO.File]::WriteAllText($GuardArtifactPath, (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine), $encoding)
[pscustomobject]$result
}
finally {
    if ($null -ne $process) {
        try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit() } } catch { }
        $process.Dispose()
    }
    foreach ($temporaryPath in @($promptPath,$stdoutPath)) {
        try { Remove-TemporaryFileWithRetry -Path $temporaryPath }
        catch { Write-Warning 'Provider temporary file cleanup was deferred.' }
    }
}
