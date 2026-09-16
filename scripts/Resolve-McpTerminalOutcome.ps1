[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('completed','waiting','failed','skipped')][string] $AgentStatus)
Set-StrictMode -Version Latest
$succeeded = $AgentStatus -eq 'completed'
[pscustomobject]@{ AgentStatus=$AgentStatus; Succeeded=$succeeded; MetricStatus=if($succeeded){'succeeded'}else{'failed'}; QualityProxy=if($succeeded){1}else{0} }
