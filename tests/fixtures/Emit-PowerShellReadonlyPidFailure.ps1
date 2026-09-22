$failure = [ordered]@{
    type = 'item.completed'
    item = [ordered]@{
        id = 'fixture-readonly-pid'
        type = 'command_execution'
        status = 'failed'
        aggregated_output = "WriteError: Cannot overwrite variable PID because it is read-only or constant."
    }
} | ConvertTo-Json -Compress
Write-Output $failure