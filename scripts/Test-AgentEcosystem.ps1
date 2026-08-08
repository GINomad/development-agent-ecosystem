[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$root = Get-EcosystemRoot
$checks = [Collections.Generic.List[object]]::new()

function Add-Check {
    param([string] $Name, [string] $Detail)
    $checks.Add([pscustomobject]@{ Name=$Name; Status='passed'; Detail=$Detail })
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })
$parseErrors = [Collections.Generic.List[object]]::new()
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) {
        $parseErrors.Add([pscustomobject]@{ File=$file.FullName; Line=$error.Extent.StartLineNumber; Message=$error.Message })
    }
}
if ($parseErrors.Count) { throw "PowerShell syntax validation failed: $($parseErrors | ConvertTo-Json -Depth 5 -Compress)" }
Add-Check -Name 'powershell-syntax' -Detail "$($powerShellFiles.Count) files"

$automaticVariableWrites = @($powerShellFiles | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw) -match '(?im)^\s*\$pid\b\s*='
})
if ($automaticVariableWrites.Count) {
    throw "PowerShell scripts must not assign to the read-only automatic variable `$PID: $($automaticVariableWrites.FullName -join ', ')"
}
Add-Check -Name 'automatic-variable-writes' -Detail 'No assignments to $PID'

$jsonFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Recurse -Filter '*.json' -File)) { $jsonFiles.Add($file) }
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root '.agents\plugins\marketplace.json')))
$jsonFiles.Add((Get-Item -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\.codex-plugin\plugin.json')))
foreach ($file in $jsonFiles) { $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json }
Add-Check -Name 'json-syntax' -Detail "$($jsonFiles.Count) files"

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
Add-Check -Name 'configuration-semantics' -Detail "mode=$($config.operation.mode); repositories=$(@($config.repositories).Count); agents=$(@($config.agents).Count)"

$skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'plugins\development-agent-ecosystem\skills') -Recurse -Filter 'SKILL.md' -File)
foreach ($file in $skillFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -notmatch '(?s)^---\r?\nname:\s*[a-z0-9-]+\r?\ndescription:\s*.+?\r?\n---') {
        throw "Invalid or missing skill frontmatter: $($file.FullName)"
    }
}
Add-Check -Name 'skill-frontmatter' -Detail "$($skillFiles.Count) skills"

$agentOutput = Join-Path $OutputRoot 'agents'
& (Join-Path $PSScriptRoot 'Sync-AgentDefinitions.ps1') -ConfigPath $ConfigPath -OutputDirectory $agentOutput -CodexHome $CodexHome | Out-Null
$tomlFiles = @(Get-ChildItem -LiteralPath $agentOutput -Filter '*.toml' -File)
if ($tomlFiles.Count -ne @($config.agents).Count) { throw 'Generated agent definition count does not match configuration.' }
foreach ($file in $tomlFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -notmatch '(?m)^name = ' -or $content -notmatch '(?m)^developer_instructions = ' -or $content -notmatch '(?m)^\[\[skills\.config\]\]') {
        throw "Generated agent TOML is incomplete: $($file.FullName)"
    }
}
Add-Check -Name 'agent-compilation' -Detail "$($tomlFiles.Count) TOML definitions"

$manifestPath = Join-Path (Resolve-EcosystemPath -Value ([string]$config.knowledge.managedRoot) -Config $config -CodexHome $CodexHome) '.knowledge-import.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Knowledge import manifest is missing: $manifestPath" }
$knowledgeManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (@($knowledgeManifest.entries).Count -lt 1) { throw 'Knowledge import manifest contains no entries.' }
Add-Check -Name 'knowledge-import' -Detail "$(@($knowledgeManifest.entries).Count) versioned files"

$reviewConfig = & (Join-Path $PSScriptRoot 'Sync-ReviewMonitorConfig.ps1') -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not (Test-Path -LiteralPath $reviewConfig.ConfigPath -PathType Leaf)) { throw 'Derived review monitor configuration was not generated.' }
Add-Check -Name 'review-monitor-config' -Detail $reviewConfig.ConfigPath

[pscustomobject]@{
    Passed = $true
    CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    Checks = @($checks)
}
