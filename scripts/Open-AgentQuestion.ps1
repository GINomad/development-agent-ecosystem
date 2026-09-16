[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $TaskId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string] $AgentId,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Question,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $Reason,
    [Parameter(Mandatory)][ValidateCount(1,10)][string[]] $Options,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $RecommendedOption,
    [Parameter(Mandatory)][ValidateLength(1,4000)][string] $RecommendationRationale,
    [string[]] $Evidence = @(),
    [string] $Stage = 'waiting_for_input',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$questionText = $Question.Trim()
if (-not $questionText) { throw 'Question cannot be empty.' }
$reasonText = $Reason.Trim()
$optionTexts = @($Options | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$recommendedOptionText = $RecommendedOption.Trim()
$recommendationRationaleText = $RecommendationRationale.Trim()
if (-not $reasonText) { throw 'Reason cannot be empty.' }
if (-not $optionTexts.Count) { throw 'At least one non-empty option is required.' }
if (-not @($optionTexts | Where-Object { $_.Equals($recommendedOptionText, [StringComparison]::OrdinalIgnoreCase) }).Count) {
    throw 'RecommendedOption must exactly match one of Options.'
}
if (-not $recommendationRationaleText) { throw 'RecommendationRationale cannot be empty.' }
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if (-not @($config.agents | Where-Object { [string]$_.id -eq $AgentId }).Count) { throw "Unknown agent '$AgentId'." }
$taskPath = Join-Path (Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome) "tasks\$TaskId\task.json"
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) { throw "Task '$TaskId' was not found." }

$humanIntervention = [pscustomobject][ordered]@{
    required = $true
    request = $questionText
    reason = $reasonText
    options = @($optionTexts)
    recommendedOption = $recommendedOptionText
    recommendationRationale = $recommendationRationaleText
}
$summaryLines = @(
    ('Action required: {0}' -f $questionText)
    ('Why human intervention is required: {0}' -f $reasonText)
    'Options:'
)
for ($index = 0; $index -lt $optionTexts.Count; $index++) {
    $summaryLines += ('{0}. {1}' -f ($index + 1), $optionTexts[$index])
}
$summaryLines += ('Recommended option: {0}' -f $recommendedOptionText)
$summaryLines += ('Why this option: {0}' -f $recommendationRationaleText)
$summary = $summaryLines -join [Environment]::NewLine
$event = & (Join-Path $PSScriptRoot 'Add-TaskEvent.ps1') -TaskId $TaskId -Actor $AgentId -Type 'question-opened' -Summary $summary -Evidence $Evidence -HumanIntervention $humanIntervention -ConfigPath $ConfigPath -CodexHome $CodexHome
& (Join-Path $PSScriptRoot 'Set-AgentTaskStatus.ps1') -TaskId $TaskId -Status waiting_for_input -AgentId $AgentId -AgentStatus waiting -Stage $Stage -Message $summary -Actor $AgentId -ConfigPath $ConfigPath -CodexHome $CodexHome | Out-Null

[pscustomobject]@{
    TaskId = $TaskId
    QuestionId = [string]$event.eventId
    AgentId = $AgentId
    Question = $questionText
    HumanIntervention = $humanIntervention
    TimestampUtc = [string]$event.timestampUtc
}
