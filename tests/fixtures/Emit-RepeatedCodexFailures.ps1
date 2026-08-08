$failure = [ordered]@{
    type = 'item.completed'
    item = [ordered]@{
        id = 'fixture'
        type = 'command_execution'
        status = 'failed'
        aggregated_output = 'windows sandbox: CreateProcessWithLogonW failed: 1260'
    }
} | ConvertTo-Json -Compress
1..3 | ForEach-Object {
    Write-Output $failure
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Seconds 30
