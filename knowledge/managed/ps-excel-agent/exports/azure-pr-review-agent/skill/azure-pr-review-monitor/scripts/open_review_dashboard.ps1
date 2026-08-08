[CmdletBinding()]
param(
    [string] $ReviewPath,
    [ValidateRange(1024, 65535)][int] $Port = 47831,
    [switch] $NoBrowser,
    [switch] $Server
)

$ErrorActionPreference = 'Stop'
$DataRoot = Join-Path $env:LOCALAPPDATA 'Codex\azure-pr-review-monitor'
$ReportsRoot = Join-Path $DataRoot 'reports'
$ManagerPath = Join-Path $PSScriptRoot 'manage_review_findings.ps1'
$BaseUrl = "http://127.0.0.1:$Port"
$Utf8 = New-Object Text.UTF8Encoding($false)

function Get-LatestReviewPath {
    $statePath = Join-Path $DataRoot 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'No review state exists yet.' }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $latest = @($state.pullRequests.PSObject.Properties | ForEach-Object { $_.Value } |
        Where-Object { $_.reportPath -and (Test-Path -LiteralPath $_.reportPath) } |
        Sort-Object reviewedAtUtc -Descending | Select-Object -First 1)
    if (-not $latest) { throw 'No completed review exists in state.json.' }
    return [string]$latest[0].reportPath
}

function Resolve-ReviewPath {
    param([Parameter(Mandatory)][string] $Value)
    $name = [IO.Path]::GetFileName($Value)
    if ($name -ne $Value -and [IO.Path]::IsPathRooted($Value)) {
        $candidate = [IO.Path]::GetFullPath($Value)
    }
    else {
        if ($name -ne $Value) { throw 'Review paths may not contain directories.' }
        $candidate = [IO.Path]::GetFullPath((Join-Path $ReportsRoot $name))
    }
    $root = [IO.Path]::GetFullPath($ReportsRoot).TrimEnd('\') + '\'
    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not $candidate.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $candidate)) {
        throw 'The requested review is outside the reports directory or does not exist.'
    }
    return $candidate
}

function Get-ReviewUrl {
    param([Parameter(Mandatory)][string] $Path)
    $htmlName = [IO.Path]::GetFileName([IO.Path]::ChangeExtension($Path, '.html'))
    return "$BaseUrl/review/$([Uri]::EscapeDataString($htmlName))"
}

function Send-Bytes {
    param($Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $Bytes.Length
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:"
    $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $response.Close()
}

function Send-Text {
    param($Context, [int]$StatusCode, [string]$ContentType, [string]$Text)
    Send-Bytes $Context $StatusCode $ContentType ($Utf8.GetBytes($Text))
}

function Send-Json {
    param($Context, [int]$StatusCode, $Value)
    Send-Text $Context $StatusCode 'application/json; charset=utf-8' ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Read-JsonBody {
    param($Request)
    if ($Request.ContentLength64 -lt 1 -or $Request.ContentLength64 -gt 65536) { throw 'Invalid request body size.' }
    $bytes = New-Object byte[] $Request.ContentLength64
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $read = $Request.InputStream.Read($bytes, $offset, $bytes.Length - $offset)
        if ($read -le 0) { break }
        $offset += $read
    }
    if ($offset -ne $bytes.Length) { throw 'Incomplete request body.' }
    return $Utf8.GetString($bytes) | ConvertFrom-Json
}

$initialReview = Resolve-ReviewPath $(if ($ReviewPath) { $ReviewPath } else { Get-LatestReviewPath })
$initialUrl = Get-ReviewUrl $initialReview
try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 1
    if ($health.status -eq 'ok' -and $health.service -eq 'codex-pr-review-dashboard') {
        if (-not $NoBrowser) { Start-Process $initialUrl }
        Write-Output "Dashboard is already running at $initialUrl"
        exit 0
    }
}
catch { }

if (-not $Server) {
    $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $stdoutPath = Join-Path $DataRoot 'dashboard.out.log'
    $stderrPath = Join-Path $DataRoot 'dashboard.err.log'
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $launchArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Server -NoBrowser -Port $Port -ReviewPath `"$initialReview`""
    $process = Start-Process -FilePath $powerShellPath -ArgumentList $launchArguments -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    [IO.File]::WriteAllText((Join-Path $DataRoot 'dashboard.pid'), [string]$process.Id, $Utf8)
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        try {
            $health = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 1
            if ($health.status -eq 'ok' -and $health.service -eq 'codex-pr-review-dashboard') { $ready = $true; break }
        }
        catch { }
    }
    if (-not $ready) {
        $details = if (Test-Path $stderrPath) { [IO.File]::ReadAllText($stderrPath, $Utf8).Trim() } else { '' }
        throw "Dashboard failed to start. $details"
    }
    if (-not $NoBrowser) { Start-Process $initialUrl }
    Write-Output "Dashboard started in a hidden process at $initialUrl"
    exit 0
}
if (-not (Test-Path -LiteralPath $ManagerPath)) { throw "Finding manager was not found at $ManagerPath." }
$csrfToken = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }))
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("$BaseUrl/")
$listener.Start()
[IO.File]::WriteAllText((Join-Path $DataRoot 'dashboard.pid'), [string]$PID, $Utf8)
Write-Output "Interactive review dashboard: $initialUrl"
if (-not $NoBrowser) { Start-Process $initialUrl }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/health') {
                Send-Json $context 200 @{ status = 'ok'; service = 'codex-pr-review-dashboard' }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/') {
                $latestUrl = Get-ReviewUrl (Get-LatestReviewPath)
                $context.Response.StatusCode = 302
                $context.Response.RedirectLocation = $latestUrl
                $context.Response.Close()
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path.StartsWith('/review/')) {
                $htmlName = [Uri]::UnescapeDataString($path.Substring('/review/'.Length))
                if ([IO.Path]::GetFileName($htmlName) -ne $htmlName -or -not $htmlName.EndsWith('.html')) { throw 'Invalid report name.' }
                $htmlPath = [IO.Path]::GetFullPath((Join-Path $ReportsRoot $htmlName))
                $root = [IO.Path]::GetFullPath($ReportsRoot).TrimEnd('\') + '\'
                if (-not $htmlPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $htmlPath)) { throw 'Report not found.' }
                $html = [IO.File]::ReadAllText($htmlPath, $Utf8).Replace('__CODEX_REVIEW_CSRF__', $csrfToken)
                Send-Text $context 200 'text/html; charset=utf-8' $html
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/findings') {
                $review = Resolve-ReviewPath ([string]$request.QueryString['review'])
                $sidecar = [IO.Path]::ChangeExtension($review, '.findings.json')
                if (-not (Test-Path $sidecar)) { throw 'Finding metadata not found.' }
                Send-Text $context 200 'application/json; charset=utf-8' ([IO.File]::ReadAllText($sidecar, $Utf8))
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/action') {
                if (-not [string]::Equals($request.Headers['X-Codex-Review-Token'], $csrfToken, [StringComparison]::Ordinal)) {
                    Send-Json $context 403 @{ ok = $false; error = 'Invalid dashboard session token.' }
                    continue
                }
                $payload = Read-JsonBody $request
                $review = Resolve-ReviewPath ([string]$payload.review)
                $findingId = [string]$payload.findingId
                $actionMap = @{ bypass = 'Bypass'; falsePositive = 'FalsePositive'; restore = 'Restore'; publish = 'Publish' }
                $action = [string]$actionMap[[string]$payload.action]
                if (-not $action -or -not $findingId) { throw 'Invalid finding action.' }
                $arguments = @{ Action = $action; FindingId = $findingId; ReviewPath = $review; DataRoot = $DataRoot }
                if ($action -in @('Bypass', 'FalsePositive')) {
                    if ([string]::IsNullOrWhiteSpace([string]$payload.reason)) { throw 'A reason is required.' }
                    $scope = [string]$payload.scope
                    if ($scope -notin @('repository', 'pull-request')) { throw 'Invalid disposition scope.' }
                    $arguments.Scope = $scope
                    $arguments.Reason = [string]$payload.reason
                    if ($action -eq 'Bypass') { $arguments.ExpiresAt = [string]$payload.expiresAt }
                }
                if ($action -eq 'Publish' -and -not [string]::Equals([string]$payload.confirmation, $findingId, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Type the finding ID exactly to confirm publication.'
                }
                $message = (& $ManagerPath @arguments -Confirm:$false 2>&1 | Out-String).Trim()
                $sidecarPath = [IO.Path]::ChangeExtension($review, '.findings.json')
                $metadata = Get-Content -Raw -LiteralPath $sidecarPath | ConvertFrom-Json
                $finding = @($metadata.findings | Where-Object { $_.FindingId -eq $findingId } | Select-Object -First 1)
                Send-Json $context 200 @{ ok = $true; message = $message; finding = $finding[0] }
                continue
            }
            Send-Json $context 404 @{ ok = $false; error = 'Not found.' }
        }
        catch {
            try { Send-Json $context 400 @{ ok = $false; error = $_.Exception.Message } } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    $pidPath = Join-Path $DataRoot 'dashboard.pid'
    if ((Test-Path $pidPath) -and ([IO.File]::ReadAllText($pidPath).Trim() -eq [string]$PID)) { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue }
}
