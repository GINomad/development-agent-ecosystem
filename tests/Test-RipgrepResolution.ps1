[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ecosystemModule = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/AgentEcosystem.psm1') -Force -PassThru
$installed = Resolve-RipgrepPath
if (-not $installed) { throw 'An installed ripgrep is required for source validation.' }
$originalPath = $env:PATH
$originalLocalAppData = $env:LOCALAPPDATA
$fixture = Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
$bin = Join-Path $fixture 'OpenAI/Codex/bin/test-version'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item -LiteralPath $installed -Destination (Join-Path $bin 'rg.exe')
Set-Content -LiteralPath (Join-Path $fixture 'probe.ps1') -Value '# ripgrep resolution probe' -Encoding UTF8
try {
    $env:PATH = Join-Path $fixture 'no-path-tools'
    $env:LOCALAPPDATA = $fixture
    if (Get-Command rg.exe, rg -CommandType Application -ErrorAction SilentlyContinue) { throw 'Fixture still resolves ripgrep through PATH.' }
    $resolved = Resolve-RipgrepPath
    if (-not $resolved) { throw 'Installed ripgrep was not resolved without PATH.' }
    $version = @(& $resolved --version)
    if ($LASTEXITCODE -ne 0 -or $version[0] -notmatch '^ripgrep ') { throw 'Resolved ripgrep did not execute.' }
    $files = @(& $resolved --files $fixture -g '*.ps1')
    if ($LASTEXITCODE -ne 0 -or -not @($files | Where-Object { (Split-Path -Leaf $_) -eq 'probe.ps1' }).Count) { throw 'PATH-independent source enumeration failed.' }
    # A long-lived workflow can load another module with the same name.
    # Bind the probe to the canonical import, never a name-based module array.
    $foreignPath = Join-Path $fixture 'foreign/AgentEcosystem.psm1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $foreignPath) -Force | Out-Null
    'Export-ModuleMember' | Set-Content -LiteralPath $foreignPath -Encoding UTF8
    $foreignModule = Import-Module $foreignPath -Force -PassThru
    try {
        if (@(Get-Module AgentEcosystem).Count -lt 2) { throw 'Duplicate module-name fixture was not established.' }
        $desktopResolved = & $ecosystemModule {
            function Resolve-CodexCliPath { return $null }
            Resolve-RipgrepPath
        }
    }
    finally {
        Remove-Module -ModuleInfo $foreignModule -Force
    }
    if ($desktopResolved -ne (Join-Path $bin 'rg.exe')) { throw 'Desktop bundled ripgrep fallback did not resolve the fixture installation.' }
    if ($env:PATH -ne (Join-Path $fixture 'no-path-tools')) { throw 'Resolver unexpectedly changed process PATH.' }
}
finally {
    $env:PATH = $originalPath
    $env:LOCALAPPDATA = $originalLocalAppData
}
if ($env:PATH -ne $originalPath -or $env:LOCALAPPDATA -ne $originalLocalAppData) { throw 'Test environment was not restored.' }
[pscustomobject]@{ Passed=$true; Scenario='Installed ripgrep executes and enumerates sources with no PATH entry'; ResolvedPath=$resolved }
