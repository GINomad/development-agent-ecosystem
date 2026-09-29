Set-StrictMode -Version Latest

function Resolve-CopilotCliPath {
    param([string] $Override)
    if ($Override) {
        $overrideCommand = Get-Command $Override -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($overrideCommand -and $overrideCommand.Source) { return [IO.Path]::GetFullPath([string]$overrideCommand.Source) }
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return [IO.Path]::GetFullPath($Override) }
        if ($Override -ne 'copilot') { throw "Copilot CLI does not exist: $Override" }
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

function Resolve-ClaudeCliPath {
    param([string] $Override)
    if ($Override) {
        $overrideCommand = Get-Command $Override -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($overrideCommand -and $overrideCommand.Source) { return [IO.Path]::GetFullPath([string]$overrideCommand.Source) }
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return [IO.Path]::GetFullPath($Override) }
        if ($Override -ne 'claude') { throw "Claude CLI does not exist: $Override" }
    }
    $command = Get-Command claude.exe, claude.cmd, claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return [IO.Path]::GetFullPath([string]$command.Source) }
    $nativePath = Join-Path ([string]$env:USERPROFILE) '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $nativePath -PathType Leaf) { return [IO.Path]::GetFullPath($nativePath) }
    throw 'Claude CLI was not found. Install Claude Code, then run claude auth login.'
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
Export-ModuleMember -Function Resolve-CopilotCliPath, Resolve-ClaudeCliPath, Get-CopilotEventSummary
