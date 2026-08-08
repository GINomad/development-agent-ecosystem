[CmdletBinding()]
param(
    [switch] $NoOpen,
    [int] $MaxRequests = 0,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$root = Get-EcosystemRoot
$dashboardRoot = Join-Path $root 'dashboard'
$address = [string]$config.ui.listenAddress
$port = [int]$config.ui.port
if ($address -ne '127.0.0.1') { throw 'Dashboard is restricted to 127.0.0.1.' }

$random = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($random) } finally { $rng.Dispose() }
$token = [Convert]::ToBase64String($random).TrimEnd('=').Replace('+','-').Replace('/','_')
$prefix = 'http://' + $address + ':' + $port + '/'

function Send-Bytes {
    param($Response, [byte[]] $Bytes, [string] $ContentType, [int] $StatusCode = 200)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Bytes.Length
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Json {
    param($Response, $Value, [int] $StatusCode = 200)
    $json = ($Value | ConvertTo-Json -Depth 20 -Compress)
    Send-Bytes -Response $Response -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($json)) -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]@{} }
    return $raw | ConvertFrom-Json
}

function Quote-PowerShellLiteral {
    param([AllowEmptyString()][string] $Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-ScriptProcess {
    param([Parameter(Mandatory)][string] $ScriptPath, [Parameter(Mandatory)][hashtable] $Parameters)
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("& $(Quote-PowerShellLiteral $ScriptPath)")
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value -or ([string]$value).Length -eq 0) { continue }
        if ($value -is [bool]) {
            if ($value) { $parts.Add("-$key") }
        }
        else {
            $parts.Add("-$key $(Quote-PowerShellLiteral ([string]$value))")
        }
    }
    $command = $parts -join ' '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru
    return $process.Id
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
$url = "${prefix}?token=$token"
Write-Output "Development Agent Desk: $url"
if (-not $NoOpen -and [bool]$config.ui.openBrowser) { Start-Process $url | Out-Null }

$handled = 0
try {
    while ($listener.IsListening -and ($MaxRequests -eq 0 -or $handled -lt $MaxRequests)) {
        $context = $listener.GetContext()
        $handled++
        $request = $context.Request
        $response = $context.Response
        try {
            $path = $request.Url.AbsolutePath
            if ($path -eq '/health') {
                Send-Json -Response $response -Value @{ status='ok' }
                continue
            }
            if ($path.StartsWith('/api/')) {
                if ($request.Headers['X-Ecosystem-Token'] -ne $token) {
                    Send-Json -Response $response -Value @{ error='Invalid dashboard session token.' } -StatusCode 403
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/config') {
                    $safeRepositories = @($config.repositories | Where-Object { $_.enabled } | ForEach-Object {
                        [pscustomobject]@{ id=[string]$_.id; provider=[string]$_.provider; repository=[string]$_.repository; localWorkspace=[string]$_.localWorkspace }
                    })
                    Send-Json -Response $response -Value @{ mode=[string]$config.operation.mode; repositories=$safeRepositories }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/tasks/assigned') {
                    $result = & (Join-Path $PSScriptRoot 'Get-AssignedTaskContext.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
                    Send-Json -Response $response -Value @{ workItems=@($result.WorkItems) }
                    continue
                }
                if ($request.HttpMethod -ne 'POST') {
                    Send-Json -Response $response -Value @{ error='Method not allowed.' } -StatusCode 405
                    continue
                }
                $body = Read-JsonBody -Request $request
                if ($path -eq '/api/workflows/start') {
                    $mode = [string]$body.mode
                    if ($mode -notin @('manual','automate')) { throw 'Mode must be manual or automate.' }
                    if ($mode -eq 'manual' -and [string]::IsNullOrWhiteSpace([string]$body.taskSelector)) { throw 'Manual mode requires a task selector.' }
                    $repository = @($config.repositories | Where-Object { $_.id -eq [string]$body.repositoryId -and $_.enabled }) | Select-Object -First 1
                    if (-not $repository) { throw 'Select an enabled repository.' }
                    $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -Parameters @{
                        Mode=$mode
                        TaskSelector=[string]$body.taskSelector
                        TaskId=[string]$body.taskId
                        RepositoryId=[string]$repository.id
                        Workspace=[string]$repository.localWorkspace
                        UserInstruction=[string]$body.instruction
                        ConfigPath=$ConfigPath
                        CodexHome=$CodexHome
                    }
                    Send-Json -Response $response -Value @{ status='started'; processId=$processId; message='Workflow opened in a separate window.' }
                    continue
                }
                if ($path -eq '/api/reviewer-notes') {
                    $noteParameters = @{
                        Text = [string]$body.text
                        RepositoryId = [string]$body.repositoryId
                        PullRequestId = [int]$body.pullRequestId
                        ConfigPath = $ConfigPath
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$body.taskId)) { $noteParameters.TaskId = [string]$body.taskId }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $noteParameters.CodexHome = $CodexHome }
                    $note = & (Join-Path $PSScriptRoot 'Add-ReviewerNote.ps1') @noteParameters
                    Send-Json -Response $response -Value @{ status='saved'; note=$note }
                    continue
                }
                if ($path -eq '/api/reviews/start') {
                    $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Invoke-EnhancedReview.ps1') -Parameters @{
                        RepositoryId=[string]$body.repositoryId
                        TaskId=[string]$body.taskId
                        ConfigPath=$ConfigPath
                        CodexHome=$CodexHome
                    }
                    Send-Json -Response $response -Value @{ status='started'; processId=$processId; message='Review opened in a separate window.' }
                    continue
                }
                Send-Json -Response $response -Value @{ error='API route not found.' } -StatusCode 404
                continue
            }

            $file = switch ($path) {
                '/' { Join-Path $dashboardRoot 'index.html' }
                '/index.html' { Join-Path $dashboardRoot 'index.html' }
                '/styles.css' { Join-Path $dashboardRoot 'styles.css' }
                '/app.js' { Join-Path $dashboardRoot 'app.js' }
                default { $null }
            }
            if (-not $file) {
                Send-Json -Response $response -Value @{ error='Not found.' } -StatusCode 404
                continue
            }
            $contentType = if ($file.EndsWith('.css')) { 'text/css; charset=utf-8' } elseif ($file.EndsWith('.js')) { 'application/javascript; charset=utf-8' } else { 'text/html; charset=utf-8' }
            $content = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
            if ($file.EndsWith('index.html')) { $content = $content.Replace('__SESSION_TOKEN__', $token) }
            Send-Bytes -Response $response -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($content)) -ContentType $contentType
        }
        catch {
            if ($response.OutputStream.CanWrite) {
                Send-Json -Response $response -Value @{ error=$_.Exception.Message } -StatusCode 500
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

