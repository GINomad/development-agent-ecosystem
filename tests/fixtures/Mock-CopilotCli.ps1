param(
    [ValidateSet('success','auth','silent','repeated')][string] $Scenario='success',
    [string] $p,
    [Parameter(ValueFromRemainingArguments=$true)][string[]] $RemainingArguments
)
$ErrorActionPreference='Stop'
$RemainingArguments=@('-p',$p)+@($RemainingArguments)
[IO.File]::WriteAllText((Join-Path $PWD 'mock-arguments.json'),($RemainingArguments|ConvertTo-Json))
if ($Scenario -eq 'auth') { [Console]::Error.WriteLine('No authentication information found.'); exit 1 }
if ($Scenario -eq 'silent') { exit 0 }
if ($Scenario -eq 'repeated') {
    1..3 | ForEach-Object {
        @{type='tool.execution_complete';data=@{success=$false;error=@{message='Synthetic repeated error'}}}|ConvertTo-Json -Compress -Depth 5
    }
    Start-Sleep -Seconds 30
    exit 2
}
$promptIndex=[array]::IndexOf($RemainingArguments,'-p')
if ($promptIndex -lt 0) { throw 'Expected explicit prompt mode.' }
$prompt=[string]$RemainingArguments[$promptIndex+1]
$match=[regex]::Match($prompt,"contract at '([^']+)'")
if(-not $match.Success -or -not (Test-Path -LiteralPath $match.Groups[1].Value)){throw 'Task contract file was not passed safely.'}
$contract=Get-Content -LiteralPath $match.Groups[1].Value -Raw
if(-not $contract.Contains('MOCK_CONTRACT')){throw 'Task contract was not preserved.'}
@{type='assistant.message';data=@{content='MOCK_OK'}}|ConvertTo-Json -Compress -Depth 4
@{type='session.idle';data=@{}}|ConvertTo-Json -Compress
exit 0

