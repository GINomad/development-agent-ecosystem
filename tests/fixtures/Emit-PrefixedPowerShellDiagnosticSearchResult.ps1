$failure = [ordered]@{
    type = 'item.completed'
    item = [ordered]@{
        id = 'fixture-prefixed-search'
        type = 'command_execution'
        status = 'failed'
        aggregated_output = "tests\\fixtures\\Emit-PowerShellParserFailure.ps1: ParserError: Line |
scripts\\Invoke-GuardedCodex.ps1: Cannot overwrite variable PID because it is read-only or constant."
    }
} | ConvertTo-Json -Compress
Write-Output $failure