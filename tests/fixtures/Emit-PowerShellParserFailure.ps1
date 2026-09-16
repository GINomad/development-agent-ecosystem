$failure = [ordered]@{
    type = 'item.completed'
    item = [ordered]@{
        id = 'fixture-parser-error'
        type = 'command_execution'
        status = 'failed'
        aggregated_output = @'
ParserError: Line |
   2 |  } } | ConvertTo-Json
     |      ~
     | An empty pipe element is not allowed.
'@
    }
} | ConvertTo-Json -Compress

Write-Output $failure
Start-Sleep -Seconds 30
