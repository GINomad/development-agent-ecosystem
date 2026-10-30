[CmdletBinding()]
param([Parameter(Mandatory)] $Review, [Parameter(Mandatory)] $Verification, [Parameter(Mandatory)][string] $RepositoryId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Test-EquivalentObligation { param($Left,$Right) if($null -eq $Left -or $null -eq $Right){return $false}; foreach($name in @('evidenceKind','phase','repositoryId','reviewedCommit','responsibleProducer','state')){if([string]$Left.$name -ne [string]$Right.$name){return $false}}; return $true }
$blocking=[Collections.Generic.List[string]]::new(); $pending=[Collections.Generic.List[object]]::new()
foreach($entry in @($Review.reviewCoverage)) {
  $status=[string]$entry.status
  if($status -eq 'blocked'){$blocking.Add([string]$entry.dimension);continue}; if($status -ne 'pending-downstream'){continue}
  $obligation=$entry.downstreamObligation; $verified=@($Verification.coverageVerification|Where-Object{[string]$_.dimension -eq [string]$entry.dimension})|Select-Object -First 1
  $scope=@($Review.reviewScope.repositories|Where-Object{[string]$_.repositoryId -eq [string]$obligation.repositoryId})|Select-Object -First 1
  $valid=[string]$entry.dimension -eq 'configuration-deployment' -and $null -ne $obligation -and [string]$obligation.phase -eq 'post-push' -and [string]$obligation.responsibleProducer -eq 'pipeline_monitor' -and [string]$obligation.state -eq 'pending' -and [string]$obligation.repositoryId -eq $RepositoryId -and $null -ne $scope -and [string]$obligation.reviewedCommit -eq [string]$scope.targetRevision -and $null -ne $verified -and [string]$verified.claimedStatus -eq 'pending-downstream' -and [string]$verified.verdict -eq 'confirmed' -and (Test-EquivalentObligation $obligation $verified.downstreamObligation)
  if(-not $valid){$blocking.Add("invalid pending-downstream $([string]$entry.dimension)");continue}; $pending.Add($obligation)
}
[pscustomobject]@{Allowed=($blocking.Count -eq 0);BlockingReasons=@($blocking);PendingObligations=@($pending)}
