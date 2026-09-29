[CmdletBinding()]
param(
    [ValidateSet('hybrid','classic')][string] $Instance='hybrid',
    [ValidateRange(0,65535)][int] $Port=0,
    [string] $ClassicRoot,
    [switch] $PrepareOnly,
    [switch] $NoOpen
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$hybridRoot=Split-Path -Parent $PSScriptRoot
if ($Instance -eq 'classic') {
    if (-not $ClassicRoot) {
        $common=@(& git -C $hybridRoot rev-parse --path-format=absolute --git-common-dir)
        if ($LASTEXITCODE -ne 0 -or $common.Count -ne 1) { throw 'Pass -ClassicRoot with the existing classic checkout.' }
        $ClassicRoot=Split-Path -Parent ([string]$common[0])
    }
    $sourceRoot=(Resolve-Path -LiteralPath $ClassicRoot).Path
    if ($sourceRoot.Equals($hybridRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'ClassicRoot must point to the unchanged classic checkout.' }
} else { $sourceRoot=$hybridRoot }
$configPath=Join-Path $sourceRoot 'config/agents.json'
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
$isHybrid=$config.runtime.PSObject.Properties['hybrid'] -and [bool]$config.runtime.hybrid.enabled
if (($Instance -eq 'hybrid') -ne [bool]$isHybrid) { throw 'Instance type does not match the selected configuration.' }
if ($Port -eq 0) { $Port=[int]$config.ui.port }
if ($Port -lt 1024) { throw 'Dashboard port must be between 1024 and 65535.' }
if ($Port -ne [int]$config.ui.port) { $config.ui.port=$Port }
$config.health.dashboardHealthUrl="http://127.0.0.1:$Port/health"
$instanceDirectory=Join-Path $hybridRoot ".runtime/instances/$Instance"
$null=New-Item -ItemType Directory -Path $instanceDirectory -Force
$snapshotPath=Join-Path $instanceDirectory 'agents.json'
# The selected checkout owns path expansion through its own AgentEcosystem module.
$json=$config|ConvertTo-Json -Depth 60
$recordPath=Join-Path $instanceDirectory 'dashboard-process.json'
$scriptPath=Join-Path $sourceRoot 'scripts/Start-AgentDashboard.ps1'
$url="http://127.0.0.1:$Port/"
$description=[ordered]@{ Instance=$Instance; Root=$sourceRoot; Port=$Port; Url=$url; ConfigPath=$snapshotPath; StateRoot=[string]$config.runtime.stateRoot }
if ($PrepareOnly) { return [pscustomobject]$description }
# Never overwrite a live instance's configuration or duplicate its state controller.
if (Test-Path -LiteralPath $recordPath) {
    $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json
    $existing=Get-Process -Id ([int]$record.ProcessId) -ErrorAction SilentlyContinue
    if ($existing -and $existing.StartTime.ToUniversalTime() -eq ([datetime]$record.StartedAtUtc).ToUniversalTime()) {
        if ([int]$record.Port -ne $Port) { throw "This instance is already running on port $($record.Port). Stop that dashboard before changing its port." }
        $health=Invoke-RestMethod -Uri ($url+'health') -TimeoutSec 5
        if ($health.status -ne 'ok') { throw 'The existing dashboard is not healthy.' }
        $description['ProcessId']=$existing.Id
        $description['AlreadyRunning']=$true
        if (-not $NoOpen) { Start-Process $url | Out-Null }
        return [pscustomobject]$description
    }
}
$listener=Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listener) { throw "Port $Port is already in use. No process was stopped. Select another -Port or use the existing dashboard." }
if ($Instance -eq 'classic') {
    foreach ($running in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'")) {
        if ([int]$running.ProcessId -eq $PID) { continue }
        $command=[string]$running.CommandLine
        $encoded=[regex]::Match($command,'(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)')
        if ($encoded.Success) { try { $command += [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded.Groups[1].Value)) } catch {} }
        if ($command.Contains($scriptPath)) { throw 'A classic dashboard process already exists. Use its port; do not duplicate its state controller.' }
    }
}
[IO.File]::WriteAllText($snapshotPath,$json+[Environment]::NewLine)
$escapedScript=$scriptPath.Replace("'","''")
$escapedConfig=$snapshotPath.Replace("'","''")
$command="& '$escapedScript' -NoOpen -ConfigPath '$escapedConfig'"
$encodedCommand=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$stdout=Join-Path $instanceDirectory 'dashboard.stdout.log'
$stderr=Join-Path $instanceDirectory 'dashboard.stderr.log'
$pwsh=(Get-Process -Id $PID).Path
$process=Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encodedCommand) -WorkingDirectory $sourceRoot -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$startedAt=$process.StartTime.ToUniversalTime().ToString('o')
$ready=$false
for($attempt=0;$attempt -lt 30;$attempt++){
    $process.Refresh()
    if($process.HasExited){throw "Dashboard exited with code $($process.ExitCode). See $stderr"}
    try{$health=Invoke-RestMethod -Uri ($url+'health') -TimeoutSec 1;if($health.status -eq 'ok'){$ready=$true;break}}catch{}
    Start-Sleep -Milliseconds 200
}
$record=[ordered]@{Instance=$Instance;Root=$sourceRoot;Port=$Port;ProcessId=$process.Id;StartedAtUtc=$startedAt;ConfigPath=$snapshotPath;Url=$url}
[IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json))
if(-not $ready){throw "Dashboard process started but health is not ready. See $stderr. Process $($process.Id) was retained for diagnosis."}
$description['ProcessId']=$process.Id
$description['AlreadyRunning']=$false
if(-not $NoOpen){Start-Process $url|Out-Null}
[pscustomobject]$description

