[CmdletBinding()]
param(
    [string] $SourceId = 'planning-space-azure-boards',
    [int] $WorkItemId,
    [string] $OutputPath,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$source = @($config.taskSources | Where-Object { $_.id -eq $SourceId -and $_.enabled }) | Select-Object -First 1
if (-not $source) { throw "Enabled task source '$SourceId' was not found." }
$profile = @($config.credentialProfiles | Where-Object { $_.id -eq $source.credentialProfile }) | Select-Object -First 1
if (-not $profile) { throw "Credential profile '$($source.credentialProfile)' was not found." }
$monitorRoot = Resolve-EcosystemPath -Value ([string]$config.review.monitorSkillRoot) -Config $config -CodexHome $CodexHome
. (Join-Path $monitorRoot 'scripts\providers\provider_common.ps1')
. (Join-Path $monitorRoot 'scripts\providers\azure_devops.ps1')

function Get-PropertyValue {
    param($InputObject, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

$ids = [Collections.Generic.List[int]]::new()
if ($WorkItemId -gt 0) {
    $ids.Add($WorkItemId)
}
else {
    $assigneeClause = if ([string]$source.assignee -eq '@Me') { '@Me' } else { "'" + ([string]$source.assignee).Replace("'", "''") + "'" }
    $stateClauses = @($source.statesExcluded | ForEach-Object { "[System.State] <> '" + ([string]$_).Replace("'", "''") + "'" })
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AssignedTo] = $assigneeClause"
    if ($stateClauses.Count) { $wiql += ' AND ' + ($stateClauses -join ' AND ') }
    $wiql += ' ORDER BY [System.ChangedDate] DESC'
    $query = Invoke-AzureJson -Profile $profile -Arguments @('boards','query','--organization',[string]$source.organization,'--project',[string]$source.project,'--wiql',$wiql)
    $queryItems = if ($null -eq $query) { @() } elseif ($query.PSObject.Properties['workItems']) { @($query.workItems) } elseif ($query.PSObject.Properties['value']) { @($query.value) } else { @($query) }
    foreach ($item in $queryItems) {
        $queryId = Get-PropertyValue -InputObject $item -Name 'id'
        if ($queryId) { $ids.Add([int]$queryId) }
    }
}

$items = [Collections.Generic.List[object]]::new()
foreach ($id in $ids) {
    $workItem = Invoke-AzureJson -Profile $profile -Arguments @('boards','work-item','show','--organization',[string]$source.organization,'--id',[string]$id,'--expand','all')
    $comments = @()
    if ([bool]$source.includeComments) {
        $commentResult = Invoke-AzureJson -Profile $profile -Arguments @(
            'devops','invoke','--organization',[string]$source.organization,
            '--area','wit','--resource','workItemComments','--route-parameters',
            "project=$($source.project)","workItemId=$id",
            '--api-version','7.1-preview.4'
        )
        $commentsProperty = Get-PropertyValue -InputObject $commentResult -Name 'comments'
        $valueProperty = Get-PropertyValue -InputObject $commentResult -Name 'value'
        $comments = if ($commentsProperty) { @($commentsProperty) } elseif ($valueProperty) { @($valueProperty) } else { @($commentResult) }
    }
    $fields = $workItem.fields
    $assignedToValue = Get-PropertyValue -InputObject $fields -Name 'System.AssignedTo'
    $assignedUniqueName = Get-PropertyValue -InputObject $assignedToValue -Name 'uniqueName'
    $relationsValue = Get-PropertyValue -InputObject $workItem -Name 'relations'
    $items.Add([pscustomobject][ordered]@{
        id = [int](Get-PropertyValue -InputObject $workItem -Name 'id')
        url = "$($source.organization)/$($source.project)/_workitems/edit/$id"
        revision = [int](Get-PropertyValue -InputObject $workItem -Name 'rev')
        type = [string](Get-PropertyValue -InputObject $fields -Name 'System.WorkItemType')
        title = [string](Get-PropertyValue -InputObject $fields -Name 'System.Title')
        state = [string](Get-PropertyValue -InputObject $fields -Name 'System.State')
        assignedTo = if ($assignedUniqueName) { [string]$assignedUniqueName } else { [string]$assignedToValue }
        areaPath = [string](Get-PropertyValue -InputObject $fields -Name 'System.AreaPath')
        iterationPath = [string](Get-PropertyValue -InputObject $fields -Name 'System.IterationPath')
        changedDate = [string](Get-PropertyValue -InputObject $fields -Name 'System.ChangedDate')
        description = [string](Get-PropertyValue -InputObject $fields -Name 'System.Description')
        acceptanceCriteria = [string](Get-PropertyValue -InputObject $fields -Name 'Microsoft.VSTS.Common.AcceptanceCriteria')
        tags = [string](Get-PropertyValue -InputObject $fields -Name 'System.Tags')
        relations = @($relationsValue)
        comments = @($comments | ForEach-Object {
            $createdBy = Get-PropertyValue -InputObject $_ -Name 'createdBy'
            $authorUniqueName = Get-PropertyValue -InputObject $createdBy -Name 'uniqueName'
            [pscustomobject][ordered]@{
                id = [string](Get-PropertyValue -InputObject $_ -Name 'id')
                author = if ($authorUniqueName) { [string]$authorUniqueName } else { [string](Get-PropertyValue -InputObject $createdBy -Name 'displayName') }
                createdAt = [string](Get-PropertyValue -InputObject $_ -Name 'createdDate')
                updatedAt = [string](Get-PropertyValue -InputObject $_ -Name 'modifiedDate')
                text = [string](Get-PropertyValue -InputObject $_ -Name 'text')
            }
        })
    })
}

$result = [pscustomobject][ordered]@{
    sourceId = $SourceId
    fetchedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    mode = if ($WorkItemId -gt 0) { 'manual' } else { 'assigned' }
    workItems = @($items)
}
if (-not $OutputPath) {
    $stateRoot = Get-EcosystemStateRoot -Config $config -CodexHome $CodexHome
    $OutputPath = Join-Path $stateRoot "task-inbox\$SourceId.json"
}
Write-Utf8NoBom -Path $OutputPath -Content (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
[pscustomobject]@{ OutputPath=[IO.Path]::GetFullPath($OutputPath); WorkItemCount=$items.Count; WorkItems=@($items) }
