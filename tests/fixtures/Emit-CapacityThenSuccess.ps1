param(
    [Parameter(Mandatory)][string] $MarkerPath,
    [Parameter(ValueFromRemainingArguments=$true)][string[]] $RemainingArguments
)

if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
    [IO.File]::WriteAllText($MarkerPath, 'first attempt')
    @{ type='error'; message='Selected model is at capacity. Please try a different model.' } | ConvertTo-Json -Compress
    exit 1
}

[IO.File]::WriteAllText($MarkerPath + '.arguments', ($RemainingArguments -join '|'))
@{ type='turn.completed' } | ConvertTo-Json -Compress
exit 0
