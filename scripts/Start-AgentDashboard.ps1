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
$runspaceLogPath = Join-Path $stateRoot 'dashboard-runspaces.jsonl'
$scriptRuns = [Collections.Generic.List[object]]::new()
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

function Get-ObjectPropertyValue {
    param([AllowNull()] $Source, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Source) { return $null }
    $property = $Source.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-RequestedRepositoryIds {
    param([Parameter(Mandatory)] $Source, [switch] $Required)
    $values = @()
    if ($Source.PSObject.Properties['repositoryIds']) { $values = @($Source.repositoryIds) }
    elseif ($Source.PSObject.Properties['repositoryId']) { $values = @($Source.repositoryId) }
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($value in $values) {
        $id = [string]$value
        if ([string]::IsNullOrWhiteSpace($id) -or $ids.Contains($id)) { continue }
        $ids.Add($id)
    }
    if ($Required -and -not $ids.Count) { throw 'Select at least one enabled repository.' }
    return @($ids)
}

function Get-EnabledRepositories {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string[]] $RepositoryIds)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($id in $RepositoryIds) {
        $repository = @($Config.repositories | Where-Object { $_.id -eq $id -and $_.enabled }) | Select-Object -First 1
        if (-not $repository) { throw "Enabled repository '$id' was not found." }
        $result.Add($repository)
    }
    return @($result)
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
        elseif ($value -is [Array]) {
            $literals = @($value | ForEach-Object { Quote-PowerShellLiteral ([string]$_) })
            if ($literals.Count) { $parts.Add("-$key @($($literals -join ','))") }
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

function Start-ScriptRunspace {
    param([Parameter(Mandatory)][string] $ScriptPath, [Parameter(Mandatory)][hashtable] $Parameters, [string] $TaskId)
    $runner = [PowerShell]::Create()
    $null = $runner.AddCommand($ScriptPath)
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value -or ([string]$value).Length -eq 0) { continue }
        if ($value -is [bool]) {
            if ($value) { $null = $runner.AddParameter($key) }
        }
        else { $null = $runner.AddParameter($key, $value) }
    }
    try { $async = $runner.BeginInvoke() }
    catch { $runner.Dispose(); throw }
    $run = [pscustomobject][ordered]@{ runId=[guid]::NewGuid().ToString('N'); taskId=$TaskId; startedAtUtc=[DateTime]::UtcNow.ToString('o'); PowerShell=$runner; Async=$async }
    $scriptRuns.Add($run)
    return $run
}

function Clear-CompletedScriptRunspaces {
    for ($index = $scriptRuns.Count - 1; $index -ge 0; $index--) {
        $run = $scriptRuns[$index]
        if (-not $run.Async.IsCompleted) { continue }
        $status = 'completed'
        $diagnostic = ''
        try { $null = $run.PowerShell.EndInvoke($run.Async) }
        catch { $status = 'failed'; $diagnostic = $_.Exception.Message }
        if ($run.PowerShell.Streams.Error.Count) {
            $status = 'failed'
            $diagnostic = (($run.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
        }
        $record = [ordered]@{ type='dashboard-runspace-completed'; runId=$run.runId; taskId=$run.taskId; startedAtUtc=$run.startedAtUtc; completedAtUtc=[DateTime]::UtcNow.ToString('o'); status=$status; diagnostic=$diagnostic } | ConvertTo-Json -Compress
        [IO.File]::AppendAllText($runspaceLogPath, $record + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $run.PowerShell.Dispose()
        $scriptRuns.RemoveAt($index)
    }
}

function Stop-TaskScriptRunspaces {
    param([Parameter(Mandatory)][string] $TaskId)
    $stoppedRunIds = [Collections.Generic.List[string]]::new()
    for ($index = $scriptRuns.Count - 1; $index -ge 0; $index--) {
        $run = $scriptRuns[$index]
        if ([string]$run.taskId -ne $TaskId -or $run.Async.IsCompleted) { continue }
        try { $run.PowerShell.Stop() } catch { }
        try { $null = $run.PowerShell.EndInvoke($run.Async) } catch { }
        $stoppedRunIds.Add([string]$run.runId)
        $run.PowerShell.Dispose()
        $scriptRuns.RemoveAt($index)
    }
    return @($stoppedRunIds)
}

function Stop-ValidatedWorkflowProcessTree {
    param([Parameter(Mandatory)][int] $WorkflowProcessId, [Parameter(Mandatory)][string] $TaskId)
    if ($WorkflowProcessId -le 0 -or $WorkflowProcessId -eq $PID) { return @() }
    $rootProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$WorkflowProcessId" -ErrorAction SilentlyContinue
    if (-not $rootProcess) { return @() }
    $commandText = [string]$rootProcess.CommandLine
    $decodedCommand = ''
    $encodedMatch = [regex]::Match($commandText, '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)')
    if ($encodedMatch.Success) {
        try { $decodedCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedMatch.Groups[1].Value)) } catch { }
    }
    $validationText = $commandText + [Environment]::NewLine + $decodedCommand
    if ($validationText -notmatch [regex]::Escape('Start-DevelopmentWorkflow.ps1') -or $validationText -notmatch [regex]::Escape($TaskId)) {
        throw "Process $WorkflowProcessId is not the validated workflow owner for task '$TaskId'."
    }
    $allProcesses = @(Get-CimInstance Win32_Process)
    $processIds = [Collections.Generic.List[int]]::new()
    $processIds.Add($WorkflowProcessId)
    for ($cursor = 0; $cursor -lt $processIds.Count; $cursor++) {
        $parentId = $processIds[$cursor]
        foreach ($child in @($allProcesses | Where-Object { [int]$_.ParentProcessId -eq $parentId })) {
            $childId = [int]$child.ProcessId
            if (-not $processIds.Contains($childId)) { $processIds.Add($childId) }
        }
    }
    $stoppedIds = [Collections.Generic.List[int]]::new()
    for ($index = $processIds.Count - 1; $index -ge 0; $index--) {
        $processIdToStop = $processIds[$index]
        if (Get-Process -Id $processIdToStop -ErrorAction SilentlyContinue) {
            Stop-Process -Id $processIdToStop -Force -ErrorAction SilentlyContinue
            $stoppedIds.Add($processIdToStop)
        }
    }
    return @($stoppedIds)
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
        Clear-CompletedScriptRunspaces
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
                    $safeAgents = @($config.agents | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; name=[string]$_.name; description=[string]$_.description; requiredArtifacts=@($_.requiredArtifacts) } })
                    Send-Json -Response $response -Value @{ mode=[string]$config.operation.mode; repositories=$safeRepositories; agents=$safeAgents; taskRefreshSeconds=[int]$config.ui.taskRefreshSeconds; agentLogRefreshSeconds=[int]$config.ui.agentLogRefreshSeconds; diffContextLines=[int]$config.ui.diffContextLines; diffMaxBytes=[int]$config.ui.diffMaxBytes }
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
                if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/external-reviews') {
                    $reviewRoot = Join-Path (Resolve-EcosystemPath -Value ([string]$config.review.monitorDataRoot) -Config $config -CodexHome $CodexHome) 'reports'
                    $reports = if (Test-Path -LiteralPath $reviewRoot -PathType Container) { @(Get-ChildItem -LiteralPath $reviewRoot -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.md','.json','.txt','.log') } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 200 | ForEach-Object { [pscustomobject]@{ name=$_.Name; length=[long]$_.Length; lastWriteTimeUtc=$_.LastWriteTimeUtc.ToString('o') } }) } else { @() }
                    Send-Json -Response $response -Value @{ reports=@($reports); lifecycleIndexPath=(Join-Path $stateRoot 'pr-lifecycle-index.json') }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/external-reviews/([^/]+)$') {
                    $reportName = [Uri]::UnescapeDataString($Matches[1])
                    if ([IO.Path]::GetFileName($reportName) -ne $reportName -or [IO.Path]::GetExtension($reportName).ToLowerInvariant() -notin @('.md','.json','.txt','.log')) { throw 'Review report name is not allowed.' }
                    $reviewRoot = [IO.Path]::GetFullPath((Join-Path (Resolve-EcosystemPath -Value ([string]$config.review.monitorDataRoot) -Config $config -CodexHome $CodexHome) 'reports'))
                    $reportPath = [IO.Path]::GetFullPath((Join-Path $reviewRoot $reportName))
                    if ([IO.Path]::GetDirectoryName($reportPath) -ne $reviewRoot -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { Send-Json -Response $response -Value @{ error='Review report was not found.' } -StatusCode 404; continue }
                    $info = Get-Item -LiteralPath $reportPath
                    $maxBytes = 1048576
                    $text = [IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)
                    if ((New-Object Text.UTF8Encoding($false)).GetByteCount($text) -gt $maxBytes) { $text = $text.Substring(0, [Math]::Min($text.Length, $maxBytes)) + [Environment]::NewLine + '[report truncated]' }
                    Send-Json -Response $response -Value @{ report=@{ name=$info.Name; content=$text; length=[long]$info.Length; lastWriteTimeUtc=$info.LastWriteTimeUtc.ToString('o') } }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/tasks/([^/]+)/agents/([^/]+)/log$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    $requestedAgentId = [Uri]::UnescapeDataString($Matches[2])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    if (-not @($config.agents | Where-Object { [string]$_.id -eq $requestedAgentId }).Count) {
                        Send-Json -Response $response -Value @{ error='Agent was not found.' } -StatusCode 404
                        continue
                    }
                    $activityParameters = @{ TaskId=$requestedTaskId; AgentId=$requestedAgentId; Tail=200; ConfigPath=$ConfigPath }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $activityParameters.CodexHome = $CodexHome }
                    $result = & (Join-Path $PSScriptRoot 'Get-AgentActivity.ps1') @activityParameters
                    Send-Json -Response $response -Value @{
                        taskId=[string]$result.TaskId
                        agentId=[string]$result.AgentId
                        status=[string]$result.Status
                        generatedAtUtc=[string]$result.GeneratedAtUtc
                        entries=@($result.Entries)
                    }
                    continue
                }
                if ($request.HttpMethod -eq 'GET' -and $path -match '^/api/tasks/([^/]+)/diff$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $repositoryId = [string]$request.QueryString['repositoryId']
                    $filePath = [string]$request.QueryString['filePath']
                    if ($repositoryId -and $repositoryId -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Repository ID contains unsupported characters.' }
                    if ($filePath.Length -gt 4096 -or $filePath.IndexOf([char]0) -ge 0) { throw 'Diff file path contains unsupported characters.' }
                    $diffParameters = @{ TaskId=$requestedTaskId; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
                    if ($repositoryId) { $diffParameters.RepositoryId = $repositoryId }
                    if ($filePath) { $diffParameters.FilePath = $filePath }
                    $diffResult = & (Join-Path $PSScriptRoot 'Get-TaskDiff.ps1') @diffParameters
                    Send-Json -Response $response -Value @{ diff=$diffResult }
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
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $body -Required)
                    $repositories = @(Get-EnabledRepositories -Config $config -RepositoryIds $repositoryIds)
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
                    $resumePlan = $null
                    if ($resume) {
                        $resumePlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $resolvedTaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
                        if (-not [bool]$resumePlan.HasWork) {
                            Send-Json -Response $response -Value @{ status='already-complete'; taskId=$resolvedTaskId; resumed=$false; pendingAgents=@(); message='No unfinished agents remain. Nothing was restarted.' }
                            continue
                        }
                    }
                    $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -Parameters @{
                        Mode=$mode
                        TaskSelector=[string]$body.taskSelector
                        TaskId=$resolvedTaskId
                        RepositoryIds=$repositoryIds
                        UserInstruction=[string]$body.instruction
                        Resume=$resume
                        ConfigPath=$ConfigPath
                        CodexHome=$CodexHome
                    }
                    $pendingAgents = if ($resumePlan) { @($resumePlan.UnfinishedAgentIds) } else { @() }
                    $startMessage = if ($resume) { "Checkpoint resume started only for: $($pendingAgents -join ', ')." } else { 'Workflow opened in a separate window.' }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$resolvedTaskId; resumed=$resume; processId=$processId; executionMode='sandboxed'; repositories=@($repositoryIds); pendingAgents=$pendingAgents; message=$startMessage }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/comments$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $commentText = [string](Get-ObjectPropertyValue -Source $body -Name 'text')
                    $questionId = [string](Get-ObjectPropertyValue -Source $body -Name 'questionId')
                    $reviewFindingId = [string](Get-ObjectPropertyValue -Source $body -Name 'reviewFindingId')
                    $targetAgentId = [string](Get-ObjectPropertyValue -Source $body -Name 'targetAgentId')
                    $commentParameters = @{ TaskId=$requestedTaskId; Text=$commentText; Author='user'; ConfigPath=$ConfigPath }
                    if (-not [string]::IsNullOrWhiteSpace($questionId)) { $commentParameters.QuestionId = $questionId }
                    if (-not [string]::IsNullOrWhiteSpace($reviewFindingId)) { $commentParameters.ReviewFindingId = $reviewFindingId }
                    if (-not [string]::IsNullOrWhiteSpace($targetAgentId)) { $commentParameters.TargetAgentId = $targetAgentId }
                    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $commentParameters.CodexHome = $CodexHome }
                    $comment = & (Join-Path $PSScriptRoot 'Add-TaskComment.ps1') @commentParameters
                    $commentMessage = if ($comment.QuestionId) { 'Answer saved and linked to the selected question. Resume the workflow to continue from the input gate.' } else { 'Comment saved. A running workflow will consume it at its next checkpoint.' }
                    Send-Json -Response $response -Value @{ status='saved'; comment=$comment; message=$commentMessage }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/agents/([^/]+)/resume$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    $requestedAgentId = [Uri]::UnescapeDataString($Matches[2])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    if (-not @($config.agents | Where-Object { [string]$_.id -eq $requestedAgentId }).Count) { throw 'Agent was not found.' }
                    $taskPath = Join-Path $stateRoot "tasks\$requestedTaskId\task.json"
                    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw 'Task was not found.' }
                    $persistedTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$persistedTask.status -eq 'running') { throw "Stop task '$requestedTaskId' before restarting one agent." }
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $persistedTask -Required)
                    $parameters = @{
                        Mode=[string]$persistedTask.mode; TaskSelector=[string]$persistedTask.selector; TaskId=$requestedTaskId
                        RepositoryIds=$repositoryIds; TargetAgentId=$requestedAgentId
                        UserInstruction="Restart only agent '$requestedAgentId'. Process its unacknowledged targeted and general comments; preserve every other agent."
                        Resume=$true; ContinueChain=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
                    }
                    $elevated = [bool]$body.elevated
                    if ($elevated) {
                        if (-not [bool]$config.runtime.elevatedFallback.enabled -or -not [bool]$config.runtime.elevatedFallback.requiresDashboardApproval) { throw 'Elevated workflow execution is not enabled.' }
                        $parameters.ElevatedApproved = $true
                        $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -TaskId $requestedTaskId -Parameters $parameters
                        $processId = $PID
                        $runId = $run.runId
                        $executionMode = 'elevated-approved'
                    }
                    else {
                        $processId = Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -Parameters $parameters
                        $runId = $null
                        $executionMode = 'sandboxed'
                    }
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $requestedTaskId -Status running -AgentId $requestedAgentId -AgentStatus pending -Stage targeted_agent_queued -Message "Targeted restart queued for '$requestedAgentId'; other agents remain unchanged." -Actor user -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $requestedTaskId -Actor user -Type workflow-status -Summary "Targeted restart requested for '$requestedAgentId'." -TargetAgentId $requestedAgentId -Artifact $taskPath -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; agentId=$requestedAgentId; processId=$processId; runId=$runId; executionMode=$executionMode; pendingAgents=@($requestedAgentId); message="Only '$requestedAgentId' was scheduled for restart." }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/close$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $reason = [string](Get-ObjectPropertyValue -Source $body -Name 'reason')
                    if ([string]::IsNullOrWhiteSpace($reason) -or $reason.Trim().Length -lt 5) { throw 'A closure reason of at least 5 characters is required.' }
                    $taskPath = Join-Path $stateRoot "tasks\$requestedTaskId\task.json"
                    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw 'Task was not found.' }
                    $closure = & (Join-Path $PSScriptRoot 'Request-TaskClosure.ps1') -TaskId $requestedTaskId -Reason $reason -Kind manual -ConfigPath $ConfigPath -CodexHome $CodexHome
                    $persistedTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $persistedTask -Required)
                    $parameters = @{
                        Mode=[string]$persistedTask.mode; TaskSelector=[string]$persistedTask.selector; TaskId=$requestedTaskId
                        RepositoryIds=$repositoryIds; TargetAgentId='knowledge_keeper'
                        UserInstruction='Process the explicit manual closure request. Update verified knowledge and publish the final task summary; do not restart delivery agents.'
                        Resume=$true; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
                    }
                    $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -TaskId $requestedTaskId -Parameters $parameters
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; closure=$closure; runId=$run.runId; executionMode='elevated-approved'; targetAgentId='knowledge_keeper'; message='Manual closure saved. Knowledge Keeper is updating evidence-backed knowledge and the final task summary.' }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/reopen$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $reason = [string](Get-ObjectPropertyValue -Source $body -Name 'reason')
                    $resumeFrom = [string](Get-ObjectPropertyValue -Source $body -Name 'resumeFrom')
                    if ($resumeFrom -notin @('requirements_analyst','developer')) { throw 'Reopen target must be Requirements Analyst or Developer.' }
                    if ([string]::IsNullOrWhiteSpace($reason) -or $reason.Trim().Length -lt 5) { throw 'A reopen reason of at least 5 characters is required.' }
                    $reopen = & (Join-Path $PSScriptRoot 'Reopen-AgentTask.ps1') -TaskId $requestedTaskId -Reason $reason -ResumeFrom $resumeFrom -ConfigPath $ConfigPath -CodexHome $CodexHome
                    $taskPath = Join-Path $stateRoot "tasks\$requestedTaskId\task.json"
                    $persistedTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -TaskId $requestedTaskId -Parameters @{
                        Mode=[string]$persistedTask.mode; TaskSelector=[string]$persistedTask.selector; TaskId=$requestedTaskId; RepositoryIds=@($persistedTask.repositoryIds)
                        UserInstruction="Task revision $([int]$persistedTask.revision) was reopened: $reason"; Resume=$true; TargetAgentId=$resumeFrom
                        ElevatedApproved=$true; ContinueChain=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
                    }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; revision=$reopen.Revision; resumeFrom=$resumeFrom; runId=$run.runId; message="Task reopened as revision $($reopen.Revision). '$resumeFrom' and its downstream chain were scheduled." }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/workflow/stop$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    $taskPath = Join-Path $stateRoot "tasks\$requestedTaskId\task.json"
                    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw 'Task was not found.' }
                    $persistedTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $stoppedRunIds = @(Stop-TaskScriptRunspaces -TaskId $requestedTaskId)
                    $stoppedProcessIds = @()
                    if ($persistedTask.PSObject.Properties['workflowProcessId']) {
                        $stoppedProcessIds = @(Stop-ValidatedWorkflowProcessTree -WorkflowProcessId ([int]$persistedTask.workflowProcessId) -TaskId $requestedTaskId)
                    }
                    foreach ($agent in @($config.agents)) {
                        $agentId = [string]$agent.id
                        if ($persistedTask.PSObject.Properties['agentStatuses'] -and $persistedTask.agentStatuses.PSObject.Properties[$agentId] -and [string]$persistedTask.agentStatuses.$agentId.status -eq 'running') {
                            & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $requestedTaskId -AgentId $agentId -AgentStatus waiting -Stage stopped_by_user -Message 'Execution was stopped by the user; persisted results were preserved.' -Actor user -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                        }
                    }
                    & (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $requestedTaskId -Status interrupted -Stage stopped_by_user -Message 'Workflow stopped by the user. Resume continues from the persisted checkpoint.' -Actor user -ClearProcessId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null
                    Send-Json -Response $response -Value @{ status='stopped'; taskId=$requestedTaskId; stoppedProcessIds=@($stoppedProcessIds); stoppedRunIds=@($stoppedRunIds); message='Workflow execution stopped; task history and completed results were preserved.' }
                    continue
                }
                if ($path -match '^/api/tasks/([^/]+)/workflow/elevated$') {
                    $requestedTaskId = [Uri]::UnescapeDataString($Matches[1])
                    if ($requestedTaskId -notmatch '^[A-Za-z0-9._-]+$') { throw 'Task ID contains unsupported characters.' }
                    if (-not [bool]$config.runtime.elevatedFallback.enabled -or -not [bool]$config.runtime.elevatedFallback.requiresDashboardApproval) { throw 'Elevated workflow execution is not enabled.' }
                    $taskPath = Join-Path $stateRoot "tasks\$requestedTaskId\task.json"
                    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw 'Task was not found.' }
                    $persistedTask = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$persistedTask.status -eq 'running' -and $persistedTask.PSObject.Properties['workflowProcessId']) {
                        $runningProcess = Get-Process -Id ([int]$persistedTask.workflowProcessId) -ErrorAction SilentlyContinue
                        if ($runningProcess) { throw "Task '$requestedTaskId' already has a running workflow." }
                    }
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $persistedTask -Required)
                    $repositories = @(Get-EnabledRepositories -Config $config -RepositoryIds $repositoryIds)
                    $resumePlan = & (Join-Path $PSScriptRoot 'Get-AgentResumePlan.ps1') -TaskId $requestedTaskId -ConfigPath $ConfigPath -CodexHome $CodexHome
                    if (-not [bool]$resumePlan.HasWork) {
                        Send-Json -Response $response -Value @{ status='already-complete'; taskId=$requestedTaskId; pendingAgents=@(); message='No unfinished agents remain. Nothing was restarted.' }
                        continue
                    }
                    if ([string]$config.runtime.elevatedFallback.launchStrategy -ne 'in-process-runspace') { throw 'Unsupported elevated workflow launch strategy.' }
                    $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-DevelopmentWorkflow.ps1') -TaskId $requestedTaskId -Parameters @{
                        Mode=[string]$persistedTask.mode; TaskSelector=[string]$persistedTask.selector; TaskId=$requestedTaskId
                        RepositoryIds=$repositoryIds
                        UserInstruction='Resume after an OS-level execution denial. Process all unacknowledged comments before the next handoff.'
                        Resume=$true; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome
                    }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; processId=$PID; runId=$run.runId; executionMode='elevated-approved'; launchStrategy='in-process-runspace'; pendingAgents=@($resumePlan.UnfinishedAgentIds); message="Elevated checkpoint resume started only for: $(@($resumePlan.UnfinishedAgentIds) -join ', ')." }
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
                    $failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $recoveryEvidencePath = $null
                    $compatibilityEvidencePath = Join-Path $taskRoot 'health-check-result.json'
                    if (Test-Path -LiteralPath $compatibilityEvidencePath -PathType Leaf) {
                        try {
                            $compatibilityEvidence = Get-Content -LiteralPath $compatibilityEvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $compatibilityReady = @($compatibilityEvidence.checks | Where-Object {
                                [string]$_.id -eq 'os-policy-compatibility' -and [string]$_.status -eq 'repaired'
                            }).Count -gt 0
                            $failureText = @([string]$failure.summary, [string]$failure.diagnostic) -join [Environment]::NewLine
                            if ($compatibilityReady -and $failureText -match 'CreateProcessWithLogonW|Windows sandbox|error\s*1260') {
                                $recoveryEvidencePath = $compatibilityEvidencePath
                            }
                        }
                        catch { }
                    }
                    $attemptsPath = Join-Path $taskRoot 'health-recovery-attempts.jsonl'
                    if (-not $recoveryEvidencePath -and (Test-Path -LiteralPath $attemptsPath -PathType Leaf)) {
                        foreach ($line in @(Get-Content -LiteralPath $attemptsPath -Encoding UTF8)) {
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }
                            try {
                                $record = $line | ConvertFrom-Json
                                if ($record.failureSignature -eq $failure.failureSignature -and $record.type -eq 'recovery-completed' -and [string]$record.status -eq 'repaired') {
                                    $candidateEvidencePath = if ($record.PSObject.Properties['resultPath']) { [string]$record.resultPath } else { Join-Path $taskRoot 'health-recovery-result.json' }
                                    if (Test-Path -LiteralPath $candidateEvidencePath -PathType Leaf) { $recoveryEvidencePath = $candidateEvidencePath }
                                    break
                                }
                            }
                            catch { }
                        }
                    }
                    if ($recoveryEvidencePath) {
                        $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-HealthTargetedResume.ps1') -TaskId $requestedTaskId -Parameters @{ TaskId=$requestedTaskId; FailurePath=$failurePath; RecoveryEvidencePath=$recoveryEvidencePath; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
                        Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; processId=$PID; runId=$run.runId; targetAgentId=[string]$failure.agentId; message="Validated repair is ready. Health Check started only '$([string]$failure.agentId)' in the approved elevated profile." }
                        continue
                    }
                    $run = Start-ScriptRunspace -ScriptPath (Join-Path $PSScriptRoot 'Start-AgentHealthRecovery.ps1') -TaskId $requestedTaskId -Parameters @{ TaskId=$requestedTaskId; FailurePath=$failurePath; ElevatedApproved=$true; ConfigPath=$ConfigPath; CodexHome=$CodexHome }
                    Send-Json -Response $response -Value @{ status='started'; taskId=$requestedTaskId; processId=$PID; runId=$run.runId; targetAgentId=[string]$failure.agentId; message="One elevated Health Check repair attempt was approved. After validation it will restart only '$([string]$failure.agentId)'." }
                    continue
                }
                if ($path -eq '/api/reviewer-notes') {
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $body -Required)
                    $repositories = @(Get-EnabledRepositories -Config $config -RepositoryIds $repositoryIds)
                    $notes = foreach ($repositoryId in $repositoryIds) {
                        $noteParameters = @{
                            Text = [string]$body.text
                            RepositoryId = $repositoryId
                            PullRequestId = [int]$body.pullRequestId
                            ConfigPath = $ConfigPath
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$body.taskId)) { $noteParameters.TaskId = [string]$body.taskId }
                        if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $noteParameters.CodexHome = $CodexHome }
                        & (Join-Path $PSScriptRoot 'Add-ReviewerNote.ps1') @noteParameters
                    }
                    Send-Json -Response $response -Value @{ status='saved'; notes=@($notes); repositories=@($repositoryIds) }
                    continue
                }
                if ($path -eq '/api/reviews/start') {
                    $repositoryIds = @(Get-RequestedRepositoryIds -Source $body -Required)
                    $repositories = @(Get-EnabledRepositories -Config $config -RepositoryIds $repositoryIds)
                    $processIds = foreach ($repositoryId in $repositoryIds) {
                        Start-ScriptProcess -ScriptPath (Join-Path $PSScriptRoot 'Invoke-EnhancedReview.ps1') -Parameters @{
                            RepositoryId=$repositoryId
                            TaskId=[string]$body.taskId
                            ConfigPath=$ConfigPath
                            CodexHome=$CodexHome
                        }
                    }
                    Send-Json -Response $response -Value @{ status='started'; processIds=@($processIds); repositories=@($repositoryIds); message='A review process was opened for each selected repository.' }
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
    foreach ($run in @($scriptRuns)) {
        try { $run.PowerShell.Stop() } catch { }
        $run.PowerShell.Dispose()
    }
    $listener.Stop()
    $listener.Close()
}
