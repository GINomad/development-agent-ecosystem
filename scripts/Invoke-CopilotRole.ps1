[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Prompt,
    [Parameter(Mandatory)][string] $WorkingDirectory,
    [Parameter(Mandatory)][string] $LogPath,
    [Parameter(Mandatory)][string] $FinalResponsePath,
    [Parameter(Mandatory)][string] $GuardArtifactPath,
    [string[]] $AdditionalDirectories = @(),
    [string] $Model = 'auto',
    [ValidateSet('none','minimal','low','medium','high','xhigh','max')][string] $ReasoningEffort = 'medium',
    [string] $McpSessionPath,
    [object[]] $McpServers = @(),
    [switch] $ReadOnly,
    [string] $CliPath,
    [string[]] $CliPrefixArguments = @(),
    [ValidateRange(1,1440)][int] $MaxRunMinutes = 120,
    [ValidateRange(1,10)][int] $MaxIdenticalFailures = 3,
    [ValidateRange(100,5000)][int] $PollMilliseconds = 500,
    [scriptblock] $HeartbeatAction,
    [ValidateRange(5,300)][int] $HeartbeatIntervalSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HybridRuntime.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$cli = Resolve-CopilotCliPath -Override $CliPath
$workingPath = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$attemptId = [guid]::NewGuid().ToString('N')
$attemptDirectory = Join-Path (Split-Path -Parent $LogPath) "copilot-attempts/$attemptId"
$null = New-Item -ItemType Directory -Path $attemptDirectory -Force
$promptFile = Join-Path $attemptDirectory 'prompt.md'
[IO.File]::WriteAllText($promptFile, $Prompt, [Text.UTF8Encoding]::new($false))
# The large role prompt is read from a scoped file, never put on the Windows command line.
$entryPrompt = "Read the complete UTF-8 task contract at '$promptFile' with the view tool, then execute that contract. It is supplied by the trusted workflow host."
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $cli
$start.WorkingDirectory = $workingPath
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
foreach ($argument in $CliPrefixArguments) { $start.ArgumentList.Add($argument) }
foreach ($argument in @('-p',$entryPrompt,'--model',$Model,'--output-format=json','--stream=off',
    '--reasoning-effort',$ReasoningEffort,
    '--no-ask-user','--no-auto-update','--no-remote','--no-remote-export','--disable-builtin-mcps',
    '--log-dir',$attemptDirectory,'--usage-output-file',(Join-Path $attemptDirectory 'usage.json'))) {
    $start.ArgumentList.Add($argument)
}
$available = if ($ReadOnly) { 'view,grep,glob' } else { 'view,grep,glob,edit,create,powershell,read_powershell,write_powershell,stop_powershell' }
if ($McpSessionPath) {
    $session=Get-Content -LiteralPath $McpSessionPath -Raw|ConvertFrom-Json
    $mcpTools=@($session.allowedTools|ForEach-Object{[string]$_})
    if (@($mcpTools|Where-Object{$_ -notmatch '^[a-z_]+$'}).Count) { throw 'Invalid Copilot MCP role allowlist.' }
    if ($mcpTools.Count) {
        $mcpConfig=Join-Path $attemptDirectory 'mcp-config.json'
        $server=[ordered]@{type='stdio';command=(Get-Command powershell.exe -ErrorAction Stop).Source;args=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'Start-EcosystemReadMcpServer.ps1'));env=@{ECOSYSTEM_MCP_SESSION_PATH=[IO.Path]::GetFullPath($McpSessionPath)};tools=$mcpTools;timeout=([int]$session.toolTimeoutSeconds*1000)}
        [IO.File]::WriteAllText($mcpConfig,(@{mcpServers=@{'ecosystem-read'=$server}}|ConvertTo-Json -Depth 8))
        $start.ArgumentList.Add('--additional-mcp-config');$start.ArgumentList.Add('@'+$mcpConfig)
        $start.ArgumentList.Add('--enable-mcp-server=ecosystem-read')
        foreach($tool in $mcpTools){$available+=",ecosystem-read-$tool";$start.ArgumentList.Add("--allow-tool=ecosystem-read($tool)")}
    }
}
foreach($mcpServer in @($McpServers|Where-Object{[string]$_.name -ne 'ecosystem-read'})){
    $serverName=[string]$mcpServer.name
    $serverTools=@($mcpServer.roleTools|ForEach-Object{[string]$_})
    if($serverName -notmatch '^[A-Za-z0-9._-]+$' -or -not $serverTools.Count -or @($serverTools|Where-Object{$_ -notmatch '^[A-Za-z0-9._-]+$'}).Count){throw 'Invalid external Copilot MCP role allowlist.'}
    & $cli @CliPrefixArguments mcp get $serverName 2>$null|Out-Null
    if($LASTEXITCODE -ne 0){throw "MCP server '$serverName' is not registered in Copilot."}
    $start.ArgumentList.Add("--enable-mcp-server=$serverName")
    foreach($tool in $serverTools){$available+=",$serverName-$tool";$start.ArgumentList.Add("--allow-tool=$serverName($tool)")}
}
$start.ArgumentList.Add("--available-tools=$available")
$start.ArgumentList.Add('--allow-tool=read')
if (-not $ReadOnly) {
    $start.ArgumentList.Add('--allow-tool=write')
    $start.ArgumentList.Add('--allow-tool=shell')
    foreach ($denied in @('shell(git push)','shell(git reset)','shell(git clean)')) { $start.ArgumentList.Add("--deny-tool=$denied") }
}
foreach ($directory in @($AdditionalDirectories + @($attemptDirectory) | Select-Object -Unique)) {
    $start.ArgumentList.Add('--add-dir')
    $start.ArgumentList.Add([IO.Path]::GetFullPath($directory))
}
# Explicit policy is per process. Do not inherit permissive switches from the launching shell.
foreach ($variable in @('COPILOT_ALLOW_ALL','COPILOT_ASSISTED_APPROVAL','COPILOT_GITHUB_PROMPT_MODE_REPO_HOOKS',
    'COPILOT_GITHUB_PROMPT_MODE_EXTENSIONS','GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS','GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS')) {
    $null = $start.Environment.Remove($variable)
}
$start.Environment['GITHUB_COPILOT_PROMPT_MODE_REPO_HOOKS'] = 'false'
$start.Environment['GITHUB_COPILOT_PROMPT_MODE_EXTENSIONS'] = 'false'
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$started = [DateTime]::UtcNow
$lastHeartbeat = $started
$exitCode = 1
$guardTriggered = $false
$reason = ''
$lastFailure = ''
$failureCount = 0
$lastResponse = ''
$stderr = ''
$processStarted = $false
try {
    if (-not $process.Start()) { throw 'Could not start Copilot CLI.' }
    $processStarted=$true
    $lineTask = $process.StandardOutput.ReadLineAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $eof = $false
    while (-not $process.HasExited -or -not $eof) {
        # Enforce deadlines and renew ownership even under a continuous event stream.
        if (([DateTime]::UtcNow-$started).TotalMinutes -ge $MaxRunMinutes) {
            $guardTriggered=$true
            $reason='Copilot execution timeout.'
            if (-not $process.HasExited) { $process.Kill($true) }
            break
        }
        if ($HeartbeatAction -and ([DateTime]::UtcNow-$lastHeartbeat).TotalSeconds -ge $HeartbeatIntervalSeconds) {
            & $HeartbeatAction | Out-Null
            $lastHeartbeat=[DateTime]::UtcNow
        }
        if ($lineTask.IsCompleted -and -not $eof) {
            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) { $eof = $true } else {
                [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
                $summary = Get-CopilotEventSummary -Line $line
                if ($summary) {
                    if ($summary.Content) { $lastResponse = $summary.Content }
                    if ($summary.Failure) {
                        if ($lastFailure -eq $summary.Failure) { $failureCount++ } else { $lastFailure=$summary.Failure; $failureCount=1 }
                        if ($summary.Type -in @('session.error','error') -or $failureCount -ge $MaxIdenticalFailures) {
                            $guardTriggered=$true
                            $reason="Copilot failure: $lastFailure"
                        }
                    }
                }
                if ($guardTriggered) { if (-not $process.HasExited) { $process.Kill($true) }; break }
                $lineTask = $process.StandardOutput.ReadLineAsync()
                continue
            }
        }

        if (-not $eof -or -not $process.HasExited) { Start-Sleep -Milliseconds $PollMilliseconds }
    }
    $process.WaitForExit()
    $exitCode=$process.ExitCode
    $stderr=$stderrTask.GetAwaiter().GetResult()
    if ($stderr) {
        [IO.File]::AppendAllText($LogPath, ((@{ type='copilot-stderr'; text=$stderr } | ConvertTo-Json -Compress) + [Environment]::NewLine))
    }
    if ($exitCode -eq 0 -and -not $lastResponse -and -not $guardTriggered) {
        $guardTriggered=$true
        $reason='Copilot exited without a final assistant message.'
    }
    if ($lastResponse) { [IO.File]::WriteAllText($FinalResponsePath,$lastResponse) }
} finally {
    if ($processStarted -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $result=[ordered]@{
        provider='copilot'; model=$Model; reasoningEffort=$ReasoningEffort; attemptId=$attemptId; exitCode=$exitCode
        guardTriggered=$guardTriggered; reason=$reason; failureDetail=$lastFailure
        failureKind=if ($stderr -match '(?i)authentication|not logged|unauthorized') { 'authentication' } else { 'runtime' }
        startedAtUtc=$started.ToString('o'); completedAtUtc=[DateTime]::UtcNow.ToString('o')
        logPath=$LogPath; finalResponsePath=$FinalResponsePath
        usagePath=(Join-Path $attemptDirectory 'usage.json'); capacityFallbackAttempted=$false
    }
    [IO.File]::WriteAllText($GuardArtifactPath,($result|ConvertTo-Json -Depth 8))
    $process.Dispose()
    # Do not retain the expanded task prompt alongside the public role result.
    if (Test-Path -LiteralPath $promptFile) { Remove-Item -LiteralPath $promptFile -Force }
}
[pscustomobject]$result

