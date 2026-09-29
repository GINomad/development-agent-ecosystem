Set-StrictMode -Version Latest

function Get-AgentRuntimeRoute {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string] $AgentId)
    if (-not @($Config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown runtime role '$AgentId'." }
    $hybrid = if ($Config.runtime.PSObject.Properties['hybrid']) { $Config.runtime.hybrid } else { $null }
    if (-not $hybrid -or -not [bool]$hybrid.enabled) {
        return [pscustomobject]@{ Provider='codex'; Model=$null; RequirementsDraft=$false }
    }
    $provider = [string]$hybrid.providers.$AgentId
    if ($provider -notin @('codex','copilot')) { throw "Invalid provider for '$AgentId'." }
    if ($AgentId -in @('requirements_analyst','reviewer','review_verifier','health_check','pipeline_monitor') -and $provider -ne 'codex') {
        throw "Independent control role '$AgentId' must remain on Codex."
    }
    [pscustomobject]@{
        Provider=$provider
        Model=if ($provider -eq 'copilot') { [string]$hybrid.copilotModel } else { $null }
        RequirementsDraft=($AgentId -eq 'requirements_analyst' -and [bool]$hybrid.requirementsDraft)
    }
}

function Resolve-CopilotCliPath {
    param([string] $Override)
    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { throw "Copilot CLI does not exist: $Override" }
        return [IO.Path]::GetFullPath($Override)
    }
    $command = Get-Command copilot.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    $locations = @(
        (Join-Path $env:LOCALAPPDATA 'Programs/copilot-cli/node_modules/@github/copilot/node_modules/@github/copilot-win32-x64/copilot.exe'),
        (Join-Path $env:APPDATA 'npm/node_modules/@github/copilot/node_modules/@github/copilot-win32-x64/copilot.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/copilot.exe')
    )
    foreach ($path in $locations) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    throw 'Copilot CLI was not found. Install GitHub.Copilot or @github/copilot, then run copilot login.'
}

function Get-CopilotEventSummary {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Line)
    try { $event = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $event -or -not $event.PSObject.Properties['type']) { return $null }
    $type = if ($event.PSObject.Properties['type']) { [string]$event.type } else { '' }
    $data = if ($event.PSObject.Properties['data']) { $event.data } else { $event }
    if ($null -eq $data) { return $null }
    $content = ''
    $failure = ''
    if ($type -eq 'assistant.message' -and $data.PSObject.Properties['content']) { $content = [string]$data.content }
    if ($type -in @('session.error','error')) {
        $failure = if ($data.PSObject.Properties['message']) { [string]$data.message } else { $Line }
    }
    if ($type -eq 'tool.execution_complete' -and $data.PSObject.Properties['success'] -and -not [bool]$data.success) {
        $failure = if ($data.PSObject.Properties['error']) { $data.error | ConvertTo-Json -Compress -Depth 8 } else { 'Copilot tool execution failed.' }
    }
    [pscustomobject]@{ Type=$type; Content=$content; Failure=$failure }
}
Export-ModuleMember -Function Get-AgentRuntimeRoute, Resolve-CopilotCliPath, Get-CopilotEventSummary

