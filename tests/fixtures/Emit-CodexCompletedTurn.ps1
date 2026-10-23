param([ValidateSet('linger','native-error','late-failure','message-only')][string] $Mode = 'linger')
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'message-only') {
    [Console]::Out.WriteLine('{"type":"item.completed","item":{"type":"agent_message","text":"completed"}}')
    exit 7
}
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')
[Console]::Out.Flush()
if ($Mode -eq 'native-error') { exit 7 }
if ($Mode -eq 'late-failure') {
    [Console]::Out.WriteLine('quota limit reached')
    [Console]::Out.Flush()
}
Start-Sleep -Seconds 60
