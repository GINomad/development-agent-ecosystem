[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TaskRoot,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{12,128}$')][string] $RunId,
    [Parameter(Mandatory)][string] $ConfigPath,
    [string] $CodexHome,
    [switch] $IncludeHostCompatibilityProfile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$resolvedHome = Get-DefaultCodexHome -Override $CodexHome
$root = Get-EcosystemRoot
$bundleRoot = Join-Path $TaskRoot "execution-bundles\$RunId"
$sources = @(@($config.agents | ForEach-Object { @($_.promptPaths) + @($_.skillPaths) }) + @([string]$config.runtime.elevatedFallback.compatibilityPromptPath) | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object {
    $path = Resolve-EcosystemPath -Value ([string]$_) -Config $config -CodexHome $resolvedHome
    [pscustomobject]@{ path=$path; sha256=Get-EcosystemFileSha256 -Path $path }
})
$configJson = $config | ConvertTo-Json -Depth 80 -Compress
function Get-TextHash([string] $Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$configHash = Get-TextHash $configJson
$sourceProvenance = & (Join-Path $PSScriptRoot 'Get-EcosystemSourceFingerprint.ps1') -Root $root
$expectedProfiles = @{}
foreach ($agent in @($config.agents)) {
    $expectedProfiles[[string]$agent.name] = Get-TextHash (New-AgentToml -Agent $agent -Config $config -CodexHome $resolvedHome)
    if ($IncludeHostCompatibilityProfile) {
        $compatible = [pscustomobject][ordered]@{
            id=[string]$agent.id;name=([string]$agent.name+[string]$config.runtime.elevatedFallback.agentProfileSuffix)
            description=([string]$agent.description+' Host-compatible profile for an explicitly confirmed OS-policy fallback.')
            responsibilities=@($agent.responsibilities);model=if($agent.PSObject.Properties['model']){[string]$agent.model}else{$null}
            reasoningEffort=[string]$agent.reasoningEffort;sandboxMode=[string]$config.runtime.elevatedFallback.sandboxMode
            promptPaths=@($agent.promptPaths)+@([string]$config.runtime.elevatedFallback.compatibilityPromptPath)
            skillPaths=@($agent.skillPaths);handoffs=@($agent.handoffs);requiredArtifacts=@($agent.requiredArtifacts)
        }
        $expectedProfiles[[string]$compatible.name] = Get-TextHash (New-AgentToml -Agent $compatible -Config $config -CodexHome $resolvedHome)
    }
}
$fingerprint = Get-TextHash (($sources | ConvertTo-Json -Depth 5 -Compress) + '|' + $configHash + '|' + [bool]$IncludeHostCompatibilityProfile + '|' + $sourceProvenance.Fingerprint)
$manifestPath = Join-Path $bundleRoot 'manifest.json'
$result = Invoke-EcosystemFileLock -LockPath ($bundleRoot + '.lock') -Action {
    $reused = Test-Path -LiteralPath $manifestPath -PathType Leaf
    if ($reused) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.fingerprint -ne $fingerprint) { throw 'Immutable agent launch bundle inputs changed for the same run.' }
        if (@($manifest.agentFiles).Count -ne $expectedProfiles.Count) { throw 'Immutable agent launch bundle role set changed.' }
        $seen = @{}
        foreach ($file in @($manifest.agentFiles)) {
            $name = [string]$file.name
            $expectedPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $bundleRoot 'agents') ($name + '.toml')))
            if (-not $expectedProfiles.ContainsKey($name) -or $seen.ContainsKey($name) -or [IO.Path]::GetFullPath([string]$file.path) -ne $expectedPath -or [string]$file.sha256 -ne $expectedProfiles[$name]) { throw 'Immutable agent launch bundle profile identity changed.' }
            $seen[$name] = $true
            if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf) -or (Get-EcosystemFileSha256 -Path $expectedPath) -ne $expectedProfiles[$name]) { throw 'Immutable agent launch bundle failed its file hash check.' }
        }
    }
    else {
        $profileRoot = Join-Path $bundleRoot 'agents'
        $sync = & (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -CodexHome $resolvedHome -OutputDirectory $profileRoot -IncludeHostCompatibilityProfile:$IncludeHostCompatibilityProfile
        $revisionOutput = @(& git -C $root rev-parse HEAD 2>$null)
        $revision = if ($LASTEXITCODE -eq 0 -and $revisionOutput.Count) { [string]$revisionOutput[0] } else { $null }
        $files = @($sync.AgentFiles | ForEach-Object { [pscustomobject]@{ name=[IO.Path]::GetFileNameWithoutExtension($_); path=[string]$_; sha256=Get-EcosystemFileSha256 -Path ([string]$_) } })
        $manifest = [pscustomobject][ordered]@{ schemaVersion=1; runId=$RunId; fingerprint=$fingerprint; configSha256=$configHash; ecosystemRevision=$revision; sourceTreeFingerprint=$sourceProvenance.Fingerprint; sourceWorktreeDirty=$sourceProvenance.Dirty; sourceFileCount=$sourceProvenance.FileCount; createdAtUtc=[DateTime]::UtcNow.ToString('o'); sources=$sources; agentFiles=$files }
        Write-Utf8NoBomAtomic -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    }
    $overrides = @($manifest.agentFiles | ForEach-Object { 'agents.' + [string]$_.name + '.config_file=' + (ConvertTo-TomlString ([string]$_.path)) })
    [pscustomobject]@{ OutputDirectory=$bundleRoot; Installed=$false; AgentFiles=@($manifest.agentFiles | ForEach-Object { [string]$_.path }); ManifestPath=$manifestPath; Fingerprint=$fingerprint; ConfigSha256=$configHash; Overrides=$overrides; Reused=[bool]$reused }
}
$result
