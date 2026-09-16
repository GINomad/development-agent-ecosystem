[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome,
    [string] $OutputDirectory,
    [ValidateSet('claude')][string] $RuntimeProvider,
    [switch] $Install,
    [switch] $IncludeHostCompatibilityProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force

$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$provider = 'claude'
$resolvedCodexHome = Get-DefaultCodexHome -Override $CodexHome
if ($Install) {
    $installRoot = [string]$config.runtime.claude.agentInstallRoot
    $OutputDirectory = Resolve-EcosystemPath -Value $installRoot -Config $config -CodexHome $resolvedCodexHome
}
elseif (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Get-EcosystemRoot) ".runtime\generated\$provider-agents"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$written = [Collections.Generic.List[string]]::new()
foreach ($agent in @($config.agents)) {
    $targetName = (Get-ClaudeAgentName -Name ([string]$agent.name)) + '.md'
    $target = Join-Path $OutputDirectory $targetName
    if ((Test-Path -LiteralPath $target) -and $Install) {
        $firstLine = Get-Content -LiteralPath $target -TotalCount 1
        $expectedMarker = '---'
        if ($firstLine -ne $expectedMarker) {
            throw "Refusing to overwrite non-generated agent file: $target"
        }
    }
    $temporary = "$target.tmp"
    $content = New-AgentClaudeMarkdown -Agent $agent -Config $config -CodexHome $resolvedCodexHome
    Write-Utf8NoBom -Path $temporary -Content $content
    Move-Item -LiteralPath $temporary -Destination $target -Force
    $written.Add($target)
}

[pscustomobject]@{
    ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    OutputDirectory = $OutputDirectory
    Installed = [bool]$Install
    RuntimeProvider = $provider
    HostCompatibilityProfile = $false
    AgentFiles = @($written)
}
