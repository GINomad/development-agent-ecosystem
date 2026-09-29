[CmdletBinding()]
param([string] $CliPath, [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.runtime/copilot-connection'))
$ErrorActionPreference='Stop'
$null=New-Item -ItemType Directory -Path $OutputRoot -Force
$result=& (Join-Path $PSScriptRoot 'Invoke-CopilotRole.ps1') -CliPath $CliPath -Prompt 'Reply with exactly COPILOT_CLI_OK. Do not run shell commands or modify any files.' -WorkingDirectory $OutputRoot -LogPath (Join-Path $OutputRoot 'probe.jsonl') -FinalResponsePath (Join-Path $OutputRoot 'response.txt') -GuardArtifactPath (Join-Path $OutputRoot 'result.json') -ReadOnly -MaxRunMinutes 2
if ($result.exitCode -ne 0 -or $result.guardTriggered) { throw "Copilot connection failed ($($result.failureKind)). Run copilot login using the licensed account. See $($result.logPath)." }
$response=(Get-Content (Join-Path $OutputRoot 'response.txt') -Raw).Trim()
if ($response -ne 'COPILOT_CLI_OK') { throw "Copilot returned an unexpected probe response. See $($result.finalResponsePath)." }
[pscustomobject]@{ Connected=$true; Provider='copilot'; Response=$response; Evidence=$result.logPath }

