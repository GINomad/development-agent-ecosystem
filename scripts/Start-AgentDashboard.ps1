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
$stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
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

function Resolve-RequestedTaskId {
    param([string] $Mode, [string] $TaskSelector, [string] $TaskId)
    if ($TaskId) {
        if ($TaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
        return $TaskId
    }
    if ($Mode -eq 'manual') {
        $match = [regex]::Match($TaskSelector, '[0-9]+')
        if ($match.Success) { return "task-$($match.Value)" }
        return 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    return 'automate-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
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
                    $safeAgents = @($config.agents | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; name=[string]$_.name; description=[string]$_.description } })
                    Send-Json -Response $response -Value @{ mode=[string]$config.operation.mode; repositories=$safeRepositories; agents=$safeAgents; taskRefreshSeconds=[int]$config.ui.taskRefreshSeconds }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/tasks/assigned') {
                    $result = & (Join-Path $PSScriptRoot 'Get-AssignedTaskContext.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
                    Send-Json -Response $response -Value @{ workItems=@($result.WorkItems) }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/tasks') {
                    $taskParameters = @{ ConfigPath=$ConfigPath; IncludeCompleted=($request.QueryString['includeCompleted'] -eq 'true') }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $taskParameters.CodexHome = $CodexHome }
                    $result = & (Join-Path $PSScriptRoot 'Get-AgentTasks.ps1') @taskParameters
                    Send-Json -Response $response -Value @{ tasks=@($result.Tasks); generatedAtUtc=[string]$result.GeneratedAtUtc }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/tasks/([^/]+)/artifacts/([^/]+)$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    $artifactName = [Uri]::UnescapeDataString($Matches[2])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    if ([string]::IsNullOrWhiteSpace($artifactName) -or [IO.Path]::GetFileName($artifactName) -ne $artifactName -or $artifactName -match '[\\/]') {
                        throw 'Artifact name contains unsupported characters.'
                    }
                    $taskRoot = [IO.Path]::GetFullPath((Join-Path $stateRoot "tasks\$requestedTaskId"))
                    if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) {
                        Send-Json -Response $response -Value @{ error='Task was not found.' } -StatusCode 404
                        continue
                    }
                    $artifactPath = [IO.Path]::GetFullPath((Join-Path $taskRoot $artifactName))
                    if ([IO.Path]::GetDirectoryName($artifactPath) -ne $taskRoot -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                        Send-Json -Response $response -Value @{ error='Artifact was not found.' } -StatusCode 404
                        continue
                    }
                    $allowedExtensions = @('.json','.jsonl','.md','.txt','.log','.toml','.yaml','.yml','.xml','.html','.csv')
                    $extension = [IO.Path]::GetExtension($artifactPath).ToLowerInvariant()
                    if ($extension -notin $allowedExtensions) {
                        Send-Json -Response $response -Value @{ error='This artifact type cannot be previewed safely.' } -StatusCode 415
                        continue
                    }
                    $artifactInfo = Get-Item -LiteralPath $artifactPath
                    $maximumPreviewBytes = 1048576
                    $previewLength = [Math]::Min([long]$artifactInfo.Length, [long]$maximumPreviewBytes)
                    $bytes = New-Object byte[] ([int]$previewLength)
                    $stream = [IO.File]::OpenRead($artifactPath)
                    try { $readLength = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
                    $content = (New-Object Text.UTF8Encoding($false, $false)).GetString($bytes, 0, $readLength)
                    Send-Json -Response $response -Value @{ artifact=@{ name=$artifactInfo.Name; content=$content; length=[long]$artifactInfo.Length; truncated=([long]$artifactInfo.Length -gt $maximumPreviewBytes); lastWriteTimeUtc=$artifactInfo.LastWriteTimeUtc.ToString('o') } }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/tasks/([^/]+)$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $taskParameters = @{ TaskId=$requestedTaskId; IncludeCompleted=$true; ConfigPath=$ConfigPath }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $taskParameters.CodexHome = $CodexHome }
                    $result = & (Join-Path $PSScriptRoot 'Get-AgentTasks.ps1') @taskParameters
                    if (-not @($result.Tasks).Count) {
                        Send-Json -Response $response -Value @{ error='Task was not found.' } -StatusCode 404
                    }
                    else {
                        Send-Json -Response $response -Value @{ task=@($result.Tasks)[0]; generatedAtUtc=$result.GeneratedAtUtc }
                    }
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
                    $resolvedTaskId = Resolve-RequestedTaskId -Mode $mode -TaskSelector ([string]$body.taskSelector) -TaskId ([string]$body.taskId)
                    $existingTaskPath = Join-Path $stateRoot "tasks\$resolvedTaskId\task.json"
                    $resume = Test-Path -LiteralPath $existingTaskPath -PathType Leaf
                    if ($resume) {
                        $existingTask = Get-Content -LiteralPath $existingTaskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ([string]$existingTask.status -eq 'running' -and $existingTask.PSObject.Properties['workflowProcessId']) {
                            $runningProcess = Get-Process -Id ([int]$existingTask.workflowProcessId) -ErrorAction SilentlyContinue
                            if ($runningProcess) { throw "Task '$resolvedTaskId' already has a running workflow." }
                        }
                    }
                    $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -Parameters @{
                        Mode=$mode
                        TaskSelector=[string]$body.taskSelector
                        TaskId=$resolvedTaskId
                        RepositoryId=[string]$repository.id
                        Workspace=[string]$repository.localWorkspace
                        UserInstruction=[string]$body.instruction
                        Resume=$resume
                        ConfigPath=$ConfigPath
                        CodexHome=$CodexHome
                    }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$resolvedTaskId; resumed=$resume; processId=$processId; message='Workflow opened in a separate window.' }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/comments$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $commentParameters = @{ TaskId=$requestedTaskId; Text=[string]$body.text; Author='user'; ConfigPath=$ConfigPath }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $commentParameters.CodexHome = $CodexHome }
                    $comment = & (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') @commentParameters
                    Send-Json -Response $response -Value @{ status='saved'; comment=$comment; message='Comment saved. A running workflow will consume it at its next checkpoint.' }
                    continue
                }
                if ($path -eq '/api/health-checks/run') {
                    $healthParameters = @{ Repair=$true; ConfigPath=$ConfigPath }
                    if (-not [string]::IsNullOrWhiteSpace([string]$body.taskId)) { $healthParameters.TaskId = [string]$body.taskId }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $healthParameters.CodexHome = $CodexHome }
                    $healthResult = & (Join-Path $PSScriptRoot 'Invoke-EcosystemHealthCheck.ps1') @healthParameters
                    Send-Json -Response $response -Value @{ status='completed'; result=$healthResult.Result; resultPath=$healthResult.ResultPath }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/health-recovery/elevated$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    if (-not [bool]$config.health.automaticRecovery.elevatedFallback.enabled -or -not [bool]$config.health.automaticRecovery.elevatedFallback.requiresDashboardApproval) { throw 'Elevated recovery is not enabled.' }
                    $taskRoot = Join-Path $stateRoot "tasks\$requestedTaskId"
                    if (-not (Test-Path -LiteralPath (Join-Path $taskRoot 'task.json') -PathType Leaf)) { throw 'Task was not found.' }
                    $failurePath = Get-ChildItem -LiteralPath $taskRoot -Filter 'agent-failure-*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName
                    if (-not $failurePath) { throw 'No failure artifact is available for elevated recovery.' }
                    $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -Parameters @{ TaskId=$requestedTaskId; FailurePath=$failurePath; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; processId=$processId; message='One elevated Health Check recovery attempt was approved and started.' }
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

