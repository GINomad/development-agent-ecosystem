[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][int]$DefinitionId,
    [Parameter(Mandatory)][string]$Branch,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$QueueError,
    [Parameter(Mandatory)][string]$AzCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafeMessage {
    param([AllowNull()][object]$Value, [int]$MaximumCharacters = 6000)
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return 'Azure returned no diagnostic text.' }
    $text = [regex]::Replace($text, '(?im)(authorization|access[_-]?token|client[_-]?secret|password|pat)\s*[:=]\s*\S+', '$1=<redacted>')
    $text = [regex]::Replace($text, '(?i)([?&](?:sig|token|se|sp|sv)=)[^&\s]+', '$1<redacted>')
    if ($text.Length -gt $MaximumCharacters) { return $text.Substring($text.Length - $MaximumCharacters) }
    return $text
}

function Invoke-AzJsonResult {
    param([Parameter(Mandatory)][string[]]$Arguments)
    try {
        $output = @(& $AzCli @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_)
        $exitCode = 1
    }
    $text = (@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    $value = $null
    $parseError = $null
    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
        try { $value = $text | ConvertFrom-Json -ErrorAction Stop }
        catch { $parseError = $_.Exception.Message }
    }
    [pscustomobject]@{
        succeeded = $exitCode -eq 0 -and $null -eq $parseError
        exitCode = $exitCode
        value = $value
        message = ConvertTo-SafeMessage -Value $(if ($parseError) { "Invalid Azure JSON: $parseError" } else { $text })
    }
}

function ConvertTo-ObjectArray {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    $valueProperty = $Value.PSObject.Properties['value']
    if ($null -ne $valueProperty) { return @($valueProperty.Value) }
    return @($Value)
}

function Get-YamlScalarValues {
    param([string]$Yaml, [string]$Key)
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) + ':[ \t]*(?<value>[^#\r\n]+)'
    @([regex]::Matches($Yaml, $pattern) | ForEach-Object {
        ([string]$_.Groups['value'].Value).Trim().Trim([char[]]"'`" ")
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-YamlVariableMap {
    param([string]$Yaml)
    $variables = @{}
    foreach ($match in [regex]::Matches($Yaml, '(?m)^[ \t]*(?<name>[A-Za-z_][\w.-]*):[ \t]*(?<value>[^#\r\n]+)')) {
        $variables[[string]$match.Groups['name'].Value] = ([string]$match.Groups['value'].Value).Trim().Trim([char[]]"'`" ")
    }
    foreach ($match in [regex]::Matches($Yaml, '(?m)^[ \t]*-[ \t]*name:[ \t]*(?<name>[^#\r\n]+)\r?\n[ \t]*value:[ \t]*(?<value>[^#\r\n]+)')) {
        $name = ([string]$match.Groups['name'].Value).Trim().Trim([char[]]"'`" ")
        $variables[$name] = ([string]$match.Groups['value'].Value).Trim().Trim([char[]]"'`" ")
    }
    return $variables
}

function Resolve-YamlReference {
    param([string]$Value, [Collections.IDictionary]$Variables)
    if ($Value -match '^\$\((?<name>[^)]+)\)$' -or $Value -match '^\$\{\{\s*variables\.(?<name>[^ }]+)\s*\}\}$') {
        $name = [string]$Matches['name']
        if ($Variables.Contains($name)) { return [string]$Variables[$name] }
    }
    return $Value
}

function Get-ObjectProperty {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-VisibleResourceNames {
    param([ValidateSet('environment','service-connection')][string]$Kind)
    $arguments = if ($Kind -eq 'environment') {
        @('devops','invoke','--organization',$Organization,'--area','distributedtask','--resource','environments','--route-parameters',"project=$Project",'--api-version','7.1','--output','json')
    }
    else {
        @('devops','service-endpoint','list','--organization',$Organization,'--project',$Project,'--output','json')
    }
    $result = Invoke-AzJsonResult -Arguments $arguments
    $names = if ($result.succeeded) {
        @(ConvertTo-ObjectArray -Value $result.value | ForEach-Object {
            [string](Get-ObjectProperty -Value $_ -Name 'name')
        } | Where-Object { $_ } | Sort-Object -Unique)
    }
    else { @() }
    [pscustomobject]@{ succeeded=[bool]$result.succeeded; names=@($names); message=if ($result.succeeded) { $null } else { $result.message } }
}

function Find-SimilarResourceName {
    param([string]$MissingName, [string[]]$CandidateNames)
    $ignoredTokens = @('a','an','the','to','for')
    $missingTokens = @($MissingName.ToLowerInvariant() -split '[^a-z0-9]+' | Where-Object { $_ -and $_ -notin $ignoredTokens } | Sort-Object -Unique)
    foreach ($candidate in @($CandidateNames)) {
        $candidateTokens = @($candidate.ToLowerInvariant() -split '[^a-z0-9]+' | Where-Object { $_ -and $_ -notin $ignoredTokens } | Sort-Object -Unique)
        if ($missingTokens.Count -and (($missingTokens -join '|') -eq ($candidateTokens -join '|'))) { return $candidate }
    }
    return $null
}

function New-ResolutionOption {
    param([string]$Id, [string]$Action, [string]$Rationale)
    [pscustomobject][ordered]@{ id=$Id; action=$Action; rationale=$Rationale }
}

function New-QueueHumanIntervention {
    param(
        [string]$Reason,
        [ValidateSet('environment','service-connection','yaml','generic')][string]$Kind,
        [string]$MissingName,
        [string[]]$VisibleNames = @()
    )
    $options = [Collections.Generic.List[object]]::new()
    $similarName = if ($MissingName) { Find-SimilarResourceName -MissingName $MissingName -CandidateNames $VisibleNames } else { $null }
    if ($Kind -eq 'environment') {
        if ($similarName) {
            $options.Add((New-ResolutionOption -Id 'reuse-visible-environment' -Action "Change the pipeline Environment from '$MissingName' to '$similarName' and authorize definition $DefinitionId to use it." -Rationale 'This reuses an existing project Environment and preserves its established approvals and checks.'))
        }
        $options.Add((New-ResolutionOption -Id 'create-or-authorize-environment' -Action "Keep '$MissingName': create it if absent, or authorize definition $DefinitionId if it already exists but is protected." -Rationale 'Azure reports missing and unauthorized Environments with the same validation family, so an owner must verify both existence and pipeline permission.'))
    }
    elseif ($Kind -eq 'service-connection') {
        if ($similarName) {
            $options.Add((New-ResolutionOption -Id 'reuse-visible-service-connection' -Action "Change the pipeline service connection from '$MissingName' to '$similarName' and authorize definition $DefinitionId to use it." -Rationale 'This reuses an existing visible credential boundary instead of creating a duplicate connection.'))
        }
        $options.Add((New-ResolutionOption -Id 'create-or-authorize-service-connection' -Action "Keep '$MissingName': create it if absent, or grant definition $DefinitionId pipeline permission if it already exists." -Rationale 'Only an authorized Azure DevOps owner can create or grant access to a protected service connection.'))
    }
    elseif ($Kind -eq 'yaml') {
        $options.Add((New-ResolutionOption -Id 'fix-pipeline-yaml' -Action 'Correct the YAML or template error on the exact branch and commit, then queue a new reviewed commit.' -Rationale 'Azure cannot compile the pipeline definition, so resource permissions cannot be evaluated until the YAML is valid.'))
        $options.Add((New-ResolutionOption -Id 'verify-definition-path' -Action "Verify that definition $DefinitionId points to the intended YAML path and branch." -Rationale 'A stale definition path or revision can make valid repository YAML appear invalid to Azure.'))
    }
    else {
        $options.Add((New-ResolutionOption -Id 'inspect-azure-validation' -Action "Open definition $DefinitionId in Azure DevOps and inspect its validation and resource-authorization details." -Rationale 'The read-only API evidence is incomplete, while the Azure UI can expose the protected resource or check that needs an owner decision.'))
        $options.Add((New-ResolutionOption -Id 'grant-diagnostic-visibility' -Action 'Grant the monitor identity read access to the relevant Environment and service-connection inventories, then rerun diagnostics.' -Rationale 'Additional read visibility lets the monitor distinguish absence from authorization without changing protected resources.'))
    }
    $recommended = [string]$options[0].id
    [pscustomobject][ordered]@{
        required = $true
        reason = $Reason
        options = @($options)
        recommendedOptionId = $recommended
        recommendationRationale = [string]$options[0].rationale
    }
}

$queueMessage = ConvertTo-SafeMessage -Value $QueueError
$definitionResult = Invoke-AzJsonResult -Arguments @(
    'pipelines','build','definition','show','--id',[string]$DefinitionId,
    '--organization',$Organization,'--project',$Project,'--output','json'
)
$definition = $definitionResult.value
$definitionProcess = Get-ObjectProperty -Value $definition -Name 'process'
$definitionEvidence = [pscustomobject][ordered]@{
    lookupSucceeded = [bool]$definitionResult.succeeded
    name = [string](Get-ObjectProperty -Value $definition -Name 'name')
    revision = Get-ObjectProperty -Value $definition -Name 'revision'
    yamlPath = [string](Get-ObjectProperty -Value $definitionProcess -Name 'yamlFilename')
    message = if ($definitionResult.succeeded) { $null } else { $definitionResult.message }
}

$branchRef = if ($Branch.StartsWith('refs/heads/')) { $Branch } else { "refs/heads/$Branch" }
$previewRequest = [ordered]@{
    previewRun = $true
    resources = [ordered]@{
        repositories = [ordered]@{
            self = [ordered]@{ refName=$branchRef; version=$Commit }
        }
    }
}
$previewFile = Join-Path ([IO.Path]::GetTempPath()) "azdo-preview-$DefinitionId-$([guid]::NewGuid().ToString('N')).json"
try {
    [IO.File]::WriteAllText($previewFile, ($previewRequest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $previewResult = Invoke-AzJsonResult -Arguments @(
        'devops','invoke','--organization',$Organization,'--area','pipelines','--resource','preview',
        '--route-parameters',"project=$Project","pipelineId=$DefinitionId",'--http-method','POST',
        '--in-file',$previewFile,'--api-version','7.1','--output','json'
    )
}
finally {
    if (Test-Path -LiteralPath $previewFile -PathType Leaf) { Remove-Item -LiteralPath $previewFile -Force }
}

if (-not $previewResult.succeeded) {
    $isYamlFailure = $previewResult.message -match '(?i)yaml|template|mapping|unexpected value|did not find expected'
    $category = if ($isYamlFailure) { 'code' } else { 'infrastructure' }
    $previewResourceChecks = [Collections.Generic.List[object]]::new()
    $previewEnvironments = [Collections.Generic.List[string]]::new()
    $previewConnections = [Collections.Generic.List[string]]::new()
    if ($previewResult.message -match '(?i)\bEnvironment\s+(?<name>[A-Za-z0-9._-]+)\s+could not be found') {
        $name = [string]$Matches['name']
        $previewEnvironments.Add($name)
        $previewResourceChecks.Add([pscustomobject][ordered]@{ kind='environment'; name=$name; status='not-visible'; detail=$previewResult.message })
    }
    if ($previewResult.message -match '(?i)(?:service connection|service endpoint)\s+(?<name>[A-Za-z0-9._ -]+?)\s+(?:could not be found|does not exist|has not been authorized|is not authorized)') {
        $name = ([string]$Matches['name']).Trim()
        $previewConnections.Add($name)
        $previewResourceChecks.Add([pscustomobject][ordered]@{ kind='service-connection'; name=$name; status='not-visible'; detail=$previewResult.message })
    }
    $interventionKind = if ($isYamlFailure) { 'yaml' } elseif ($previewEnvironments.Count) { 'environment' } elseif ($previewConnections.Count) { 'service-connection' } else { 'generic' }
    $missingResourceName = if ($previewEnvironments.Count) { [string]$previewEnvironments[0] } elseif ($previewConnections.Count) { [string]$previewConnections[0] } else { '' }
    $visibleResourceNames = @()
    if ($interventionKind -in @('environment','service-connection')) {
        $resourceInventory = Get-VisibleResourceNames -Kind $interventionKind
        if ($resourceInventory.succeeded) { $visibleResourceNames = @($resourceInventory.names) }
    }
    $interventionReason = if ($isYamlFailure) {
        'Azure cannot compile the exact pipeline YAML, and the monitor is read-only and cannot change product code.'
    }
    elseif ($missingResourceName) {
        "Azure cannot resolve or authorize the referenced $interventionKind '$missingResourceName' before queueing, and the monitor cannot create resources or grant pipeline permissions."
    }
    else {
        'Azure rejected the queue request before creating a run, and the read-only preview did not identify one safely automatable correction.'
    }
    $humanIntervention = New-QueueHumanIntervention -Reason $interventionReason -Kind $interventionKind -MissingName $missingResourceName -VisibleNames $visibleResourceNames
    return [pscustomobject][ordered]@{
        diagnosticType = 'queue-validation'
        definitionId = $DefinitionId
        category = $category
        developerEligible = $isYamlFailure
        matchedSignals = @($queueMessage, $previewResult.message)
        summary = "Definition $DefinitionId queue failed and Azure dry-run preview also failed: $($previewResult.message)"
        queueError = $queueMessage
        definition = $definitionEvidence
        preview = [pscustomobject]@{ succeeded=$false; message=$previewResult.message }
        referencedResources = [pscustomobject]@{ environments=@($previewEnvironments); serviceConnections=@($previewConnections) }
        resourceChecks = @($previewResourceChecks)
        humanIntervention = $humanIntervention
    }
}

$finalYaml = [string](Get-ObjectProperty -Value $previewResult.value -Name 'finalYaml')
if ([string]::IsNullOrWhiteSpace($finalYaml)) {
    $humanIntervention = New-QueueHumanIntervention -Reason 'Azure accepted the preview request but returned no compiled YAML, so the monitor cannot identify the protected resource safely.' -Kind generic
    return [pscustomobject][ordered]@{
        diagnosticType='queue-validation'; definitionId=$DefinitionId; category='infrastructure'; developerEligible=$false
        matchedSignals=@($queueMessage,'Azure dry-run preview returned no finalYaml document.')
        summary="Definition $DefinitionId queue failed; Azure dry-run preview returned no final YAML for resource diagnosis."
        queueError=$queueMessage; definition=$definitionEvidence
        preview=[pscustomobject]@{ succeeded=$false; message='Azure dry-run preview returned no finalYaml document.' }
        referencedResources=[pscustomobject]@{ environments=@(); serviceConnections=@() }; resourceChecks=@()
        humanIntervention=$humanIntervention
    }
}
$variables = Get-YamlVariableMap -Yaml $finalYaml
$environmentNameList = [Collections.Generic.List[string]]::new()
foreach ($rawValue in @(Get-YamlScalarValues -Yaml $finalYaml -Key 'environment')) {
    $resolvedValue = Resolve-YamlReference -Value $rawValue -Variables $variables
    if ($resolvedValue -notmatch '^\$' -and -not $environmentNameList.Contains($resolvedValue)) { $environmentNameList.Add($resolvedValue) }
}
$environmentNames = @($environmentNameList | Sort-Object)
$connectionNameList = [Collections.Generic.List[string]]::new()
foreach ($match in [regex]::Matches($finalYaml, '(?m)^[ \t]*(?:azureSubscription|azureSubscriptionEndpoint|connectedServiceName|connectedServiceNameARM|containerRegistry|dockerRegistryEndpoint|kubernetesServiceEndpoint):[ \t]*(?<value>[^#\r\n]+)')) {
    $rawValue = ([string]$match.Groups['value'].Value).Trim().Trim([char[]]"'`" ")
    $resolvedValue = Resolve-YamlReference -Value $rawValue -Variables $variables
    if ($resolvedValue -notmatch '^\$' -and -not $connectionNameList.Contains($resolvedValue)) { $connectionNameList.Add($resolvedValue) }
}
$connectionNames = @($connectionNameList | Sort-Object)

$resourceChecks = [Collections.Generic.List[object]]::new()
$missingEnvironments = [Collections.Generic.List[string]]::new()
$missingConnections = [Collections.Generic.List[string]]::new()
$lookupFailures = [Collections.Generic.List[string]]::new()
$visibleEnvironments = @()
$visibleConnections = @()

if ($environmentNames.Count -gt 0) {
    $environmentResult = Invoke-AzJsonResult -Arguments @(
        'devops','invoke','--organization',$Organization,'--area','distributedtask','--resource','environments',
        '--route-parameters',"project=$Project",'--api-version','7.1','--output','json'
    )
    if ($environmentResult.succeeded) {
        $visibleEnvironments = @(ConvertTo-ObjectArray -Value $environmentResult.value | ForEach-Object {
            [string](Get-ObjectProperty -Value $_ -Name 'name')
        } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($name in $environmentNames) {
            $visible = @($visibleEnvironments | Where-Object { $_.Equals($name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if (-not $visible) { $missingEnvironments.Add($name) }
            $resourceChecks.Add([pscustomobject][ordered]@{
                kind='environment'; name=$name; status=if ($visible) { 'visible' } else { 'not-visible' }
                detail=if ($visible) { 'Environment is visible to the monitor identity.' } else { 'Environment is absent or not visible to the monitor identity in this Azure project.' }
            })
        }
    }
    else {
        $lookupFailures.Add("environment inventory: $($environmentResult.message)")
    }
}

if ($connectionNames.Count -gt 0) {
    $connectionResult = Invoke-AzJsonResult -Arguments @(
        'devops','service-endpoint','list','--organization',$Organization,'--project',$Project,'--output','json'
    )
    if ($connectionResult.succeeded) {
        $visibleConnections = @(ConvertTo-ObjectArray -Value $connectionResult.value | ForEach-Object {
            [string](Get-ObjectProperty -Value $_ -Name 'name')
        } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($name in $connectionNames) {
            $visible = @($visibleConnections | Where-Object { $_.Equals($name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if (-not $visible) { $missingConnections.Add($name) }
            $resourceChecks.Add([pscustomobject][ordered]@{
                kind='service-connection'; name=$name; status=if ($visible) { 'visible' } else { 'not-visible' }
                detail=if ($visible) { 'Service connection is visible to the monitor identity.' } else { 'Service connection is absent or not visible to the monitor identity in this Azure project.' }
            })
        }
    }
    else {
        $lookupFailures.Add("service connection inventory: $($connectionResult.message)")
    }
}

$yamlPath = if ($definitionEvidence.yamlPath) { $definitionEvidence.yamlPath } else { '<unknown>' }
if ($missingEnvironments.Count -gt 0) {
    $summary = "Definition $DefinitionId uses Environment(s) not visible in project '$Project': $($missingEnvironments -join ', '). YAML: $yamlPath."
}
elseif ($missingConnections.Count -gt 0) {
    $summary = "Definition $DefinitionId uses service connection(s) not visible in project '$Project': $($missingConnections -join ', '). YAML: $yamlPath."
}
elseif ($lookupFailures.Count -gt 0) {
    $summary = "Definition $DefinitionId dry-run preview succeeded, but resource authorization could not be fully verified: $($lookupFailures -join '; '). YAML: $yamlPath."
}
else {
    $summary = "Definition $DefinitionId dry-run preview succeeded and referenced resources are visible. The remaining queue rejection is likely a pipeline permission, resource authorization, or check configuration. YAML: $yamlPath."
}

if ($missingEnvironments.Count) {
    $interventionReason = "Azure cannot queue definition $DefinitionId because Environment '$([string]$missingEnvironments[0])' is absent or not visible to the pipeline."
    $humanIntervention = New-QueueHumanIntervention -Reason $interventionReason -Kind environment -MissingName ([string]$missingEnvironments[0]) -VisibleNames $visibleEnvironments
}
elseif ($missingConnections.Count) {
    $interventionReason = "Azure cannot queue definition $DefinitionId because service connection '$([string]$missingConnections[0])' is absent or not visible to the pipeline."
    $humanIntervention = New-QueueHumanIntervention -Reason $interventionReason -Kind service-connection -MissingName ([string]$missingConnections[0]) -VisibleNames $visibleConnections
}
elseif ($lookupFailures.Count) {
    $humanIntervention = New-QueueHumanIntervention -Reason 'The monitor lacks enough read visibility to distinguish a missing resource from a resource-authorization failure.' -Kind generic
}
else {
    $humanIntervention = New-QueueHumanIntervention -Reason 'Azure compiled the exact YAML and the referenced resources are visible, but a protected permission or check still blocks queueing.' -Kind generic
}

[pscustomobject][ordered]@{
    diagnosticType = 'queue-validation'
    definitionId = $DefinitionId
    category = 'infrastructure'
    developerEligible = $false
    matchedSignals = @($queueMessage, $summary)
    summary = $summary
    queueError = $queueMessage
    definition = $definitionEvidence
    preview = [pscustomobject]@{ succeeded=$true; message='Azure dry-run preview parsed the exact branch and commit.' }
    referencedResources = [pscustomobject]@{ environments=@($environmentNames); serviceConnections=@($connectionNames) }
    resourceChecks = @($resourceChecks)
    humanIntervention = $humanIntervention
}
