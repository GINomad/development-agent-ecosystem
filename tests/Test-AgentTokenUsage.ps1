[CmdletBinding()]
param([string]$OutputRoot=(Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/token-usage'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$writer=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Write-AgentTokenUsage.ps1'
$root=Join-Path $OutputRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$log=Join-Path $root 'workflow.jsonl'
function Save-Events($Events) { [IO.File]::WriteAllLines($log,@($Events|ForEach-Object{$_|ConvertTo-Json -Depth 12 -Compress})) }
function Read-Records { @(Get-Content (Join-Path $root 'token-usage.jsonl')|ForEach-Object{$_|ConvertFrom-Json}) }
function Write-Usage([string]$Attempt,[string]$Provider,[string]$Run='iteration-one') {
    & $writer -TaskRoot $root -TaskId task-test -AgentId developer -RunId $Run -AttemptId $Attempt -Provider $Provider -Model requested -LogPath $log -TaskRevision 3|Out-Null
}
Save-Events @(
    @{type='ecosystem-workflow-run';attemptId='old'},
    @{type='result';usage=@{input_tokens=999999;output_tokens=999999}},
    @{type='ecosystem-workflow-run';attemptId='claude-complete'},
    @{type='assistant';message=@{id='msg';model='sonnet';usage=@{input_tokens=10;output_tokens=5}}},
    @{type='result';usage=@{input_tokens=999;output_tokens=999};modelUsage=@{
        'claude-sonnet-5-5'=@{inputTokens=100;outputTokens=20;cacheReadInputTokens=40;cacheCreationInputTokens=10}
        'claude-haiku-subagent'=@{inputTokens=5;outputTokens=2;cacheReadInputTokens=0;cacheCreationInputTokens=0}
    }}
)
Write-Usage claude-complete claude
$records=Read-Records
$sonnet=@($records|Where-Object model -eq 'claude-sonnet-5-5')[0]
if($records.Count -ne 2 -or $sonnet.totalTokens -ne 170 -or $sonnet.inputTokens -ne 100 -or $sonnet.taskRevision -ne 3){throw 'Claude totals, model attribution or task revision are incorrect'}
Write-Usage claude-complete claude
if((Read-Records).Count -ne 2){throw 'Duplicate persistence double-counted usage'}
Save-Events @(
    @{type='ecosystem-workflow-run';attemptId='partial'},
    @{type='assistant';message=@{id='same';model='sonnet';usage=@{input_tokens=10;output_tokens=1;cache_read_input_tokens=0;cache_creation_input_tokens=0}}},
    @{type='assistant';message=@{id='same';model='sonnet';usage=@{input_tokens=10;output_tokens=4;cache_read_input_tokens=0;cache_creation_input_tokens=0}}}
)
Write-Usage partial claude
$partial=@(Read-Records|Where-Object attemptId -eq 'partial')[0]
if($partial.totalTokens -ne 14 -or $partial.availability -ne 'partial'){throw 'Partial message snapshots were double-counted'}
Save-Events @(
    @{type='ecosystem-workflow-run';attemptId='capacity'},
    @{type='ecosystem-provider-attempt';providerAttemptId='primary';model='sol'},
    @{type='turn.completed';usage=@{input_tokens=100;output_tokens=10;cached_input_tokens=80}},
    @{type='ecosystem-provider-attempt';providerAttemptId='fallback';model='terra'},
    @{type='turn.completed';usage=@{input_tokens=20;output_tokens=2;cached_input_tokens=15}}
)
Write-Usage capacity codex iteration-two
$capacity=@(Read-Records|Where-Object attemptId -eq 'capacity')
if($capacity.Count -ne 2 -or $capacity[0].totalTokens -ne 110 -or $capacity[1].totalTokens -ne 22 -or $capacity[1].model -ne 'terra'){throw 'Capacity fallback accounting is incorrect'}
Save-Events @(@{type='ecosystem-workflow-run';attemptId='missing'})
Write-Usage missing codex
$missing=@(Read-Records|Where-Object attemptId -eq 'missing')[0]
if($missing.availability -ne 'unavailable' -or $null -ne $missing.totalTokens){throw 'Missing usage became zero'}
Save-Events @(@{type='ecosystem-workflow-run';attemptId='copilot'})
$usagePath=Join-Path $root 'usage.json'
'{"inputTokens":50,"outputTokens":8}'|Set-Content $usagePath
& $writer -TaskRoot $root -TaskId task-test -AgentId reviewer -RunId iteration-two -AttemptId copilot -Provider copilot -Model copilot-model -LogPath $log -UsagePath $usagePath|Out-Null
$copilot=@(Read-Records|Where-Object attemptId -eq 'copilot')[0]
if($copilot.totalTokens -ne 58 -or $copilot.agentId -ne 'reviewer'){throw 'Copilot usage attribution failed'}
[pscustomobject]@{Status='passed';Checks=7;OutputRoot=$root}
