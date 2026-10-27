[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Path,
    [AllowEmptyCollection()][object[]] $KnowledgeRecords = @(),
    [string[]] $RepositoryRoots = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value($Record, [string] $Name, $Default = '') {
    if ($null -eq $Record -or -not $Record.PSObject.Properties[$Name]) { return $Default }
    $Record.$Name
}

function Test-NarrowPath([string] $Value) {
    $normalized = $Value.Replace('\','/').TrimEnd('/') -replace '^\./',''
    if ($normalized -in @('', '.', '*', '**', '**/*', '*.*')) { return $false }
    foreach ($root in $RepositoryRoots) {
        if ($normalized -eq $root.Replace('\','/').TrimEnd('/')) { return $false }
    }
    return $true
}

function Get-EnumerationKind([string] $Command, [int] $Depth = 0) {
    if ($Depth -gt 3) { return 'unclassified' }
    # Parse, never evaluate, command text. Quoted documentation is not a scan.
    # Windows provider transcripts also contain a quoted executable followed by
    # -Command, which is a native command-line representation, not valid PS syntax.
    if ($Command -match '(?is)^\s*(?:&\s*)?(?:"[^"]*(?:pwsh|powershell)(?:\.exe)?"|(?:pwsh|powershell)(?:\.exe)?)\s+(?:-NoProfile\s+)?-(?:Command|c)\s+(?<script>.+?)\s*$') {
        $inner = $Matches.script
        if (($inner.StartsWith('"') -and $inner.EndsWith('"')) -or ($inner.StartsWith("'") -and $inner.EndsWith("'"))) {
            $quote = $inner.Substring(0,1)
            $inner = $inner.Substring(1,$inner.Length-2)
            if ($quote -eq '"') { $inner = $inner.Replace('\"','"') }
            else { $inner = $inner.Replace(([string][char]39 + [char]34 + [char]39), "'") }
        }
        return Get-EnumerationKind -Command $inner -Depth ($Depth + 1)
    }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { return 'unclassified' }
    $kinds = [Collections.Generic.List[string]]::new()
    foreach ($node in $ast.FindAll({ param($candidate) $candidate -is [Management.Automation.Language.CommandAst] }, $true)) {
        $ancestor = $node.Parent
        while ($ancestor -and $ancestor -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $ancestor=$ancestor.Parent }
        if ($ancestor) { continue }
        $name = [string]$node.GetCommandName()
        $name = ($name.Replace('\','/') -split '/')[-1].ToLowerInvariant()
        if ($name -in @('pwsh','pwsh.exe','powershell','powershell.exe')) {
            $elements = @($node.CommandElements)
            for ($i=1; $i -lt $elements.Count-1; $i++) {
                if ($elements[$i].Extent.Text -in @('-Command','-c') -and $elements[$i+1] -is [Management.Automation.Language.StringConstantExpressionAst]) {
                    $kinds.Add((Get-EnumerationKind -Command $elements[$i+1].Value -Depth ($Depth+1)))
                }
            }
            continue
        }
        if ($name -notin @('rg','rg.exe','git','git.exe','get-childitem','gci','dir','ls','find','findstr','findstr.exe')) { continue }
        $arguments = [Collections.Generic.List[string]]::new()
        $dynamic = $false
        foreach ($element in @($node.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [Management.Automation.Language.StringConstantExpressionAst]) { $arguments.Add($element.Value) }
            elseif ($element -is [Management.Automation.Language.CommandParameterAst]) { $arguments.Add($element.Extent.Text) }
            else { $arguments.Add($element.Extent.Text); $dynamic = $true }
        }
        $argsList = @($arguments)
        if ($name -in @('rg','rg.exe') -and '--files' -notin $argsList) { continue }
        if ($name -in @('git','git.exe') -and 'ls-files' -notin $argsList) { continue }
        if ($name -in @('get-childitem','gci','dir','ls') -and -not @($argsList | Where-Object { $_ -match '^(?i)(-Recurse|-r|/s)$' }).Count) { continue }
        if ($dynamic) { $kinds.Add('unclassified'); continue }
        $narrow = $false
        $broadPattern = $false
        $unknown = $false
        $positionals = [Collections.Generic.List[string]]::new()
        for ($i=0; $i -lt $argsList.Count; $i++) {
            $arg = $argsList[$i]
            if ($name -in @('rg','rg.exe') -and $arg -ceq '-T') { $i++; continue }
            if ($name -in @('rg','rg.exe') -and $arg -cmatch '^-T.+$') { continue }
            if ($arg -in @('-g','--glob','--iglob','-Include','-Filter','-Name','-t','--type','-name','-iname','-path','-ipath','-regex','-iregex')) {
                if ($arg -eq '-Name' -and $name -in @('get-childitem','gci','dir','ls')) { continue }
                if ($i+1 -ge $argsList.Count) { $unknown=$true; break }
                $i++; $pattern=$argsList[$i]
                if (-not $pattern.StartsWith('!')) { if (Test-NarrowPath $pattern) { $narrow=$true } else { $broadPattern=$true } }
                continue
            }
            if ($arg -match '^(?:--(?:i?glob|type))=(?<pattern>.+)$') {
                if (-not $Matches.pattern.StartsWith('!')) { if (Test-NarrowPath $Matches.pattern) { $narrow=$true } else { $broadPattern=$true } }
                continue
            }
            if ($name -in @('rg','rg.exe') -and $arg -match '^-(?:g|t)(?<pattern>.+)$') {
                if (-not $Matches.pattern.StartsWith('!')) { if (Test-NarrowPath $Matches.pattern) { $narrow=$true } else { $broadPattern=$true } }
                continue
            }
            if ($arg -in @('-Exclude','--ignore-file','-T','--type-not','--sort','--sortr','--color','--colors','--encoding','-E','--threads','-j','--max-depth','--max-filesize','-Depth','-type','-maxdepth','-mindepth')) { $i++; continue }
            if ($arg -eq '-C' -and $name -in @('git','git.exe')) {
                if ($i+1 -ge $argsList.Count) { $unknown=$true; break }
                $i++; if (Test-NarrowPath $argsList[$i]) { $narrow=$true }; continue
            }
            if ($arg -in @('-Path','-LiteralPath')) {
                if ($i+1 -ge $argsList.Count) { $unknown=$true; break }
                $i++; $positionals.Add($argsList[$i]); continue
            }
            if ($arg -eq 'ls-files' -and $name -in @('git','git.exe')) { continue }
            if ($arg.StartsWith('-') -or $arg -in @('/s','/b','/a')) { continue }
            $positionals.Add($arg)
        }
        if ($broadPattern) { $narrow=$false }
        if ($positionals.Count -and -not @($positionals | Where-Object { -not (Test-NarrowPath $_) }).Count) { $narrow=$true }
        # A pipeline that selects file names is a targeted discovery operation.
        $pipeline = $node.Parent
        if ($pipeline -is [Management.Automation.Language.PipelineAst]) {
            foreach ($next in $pipeline.PipelineElements) {
                if ($next.Extent.StartOffset -le $node.Extent.StartOffset -or $next -isnot [Management.Automation.Language.CommandAst]) { continue }
                if ($next.GetCommandName() -in @('rg','rg.exe','grep','Select-String','Where-Object','where','?')) { $narrow=$true }
            }
        }
        $kinds.Add($(if ($unknown) { 'unclassified' } elseif ($narrow) { 'targeted' } else { 'full-scan' }))
    }
    if ($kinds.Contains('full-scan')) { return 'full-scan' }
    if ($kinds.Contains('unclassified')) { return 'unclassified' }
    if ($kinds.Contains('targeted')) { return 'targeted' }
    return 'none'
}

$coveredAttempts = @{}
$mapEventCount = 0
$excludedMapEventCount = 0
$declaredScans = [Collections.Generic.List[object]]::new()
foreach ($record in $KnowledgeRecords) {
    if ([string](Get-Value $record 'status' 'succeeded') -ne 'succeeded') { continue }
    $attempt = [string](Get-Value $record 'attemptId')
    $isMap = [string](Get-Value $record 'sourceKind') -eq 'repository-map' -and [string](Get-Value $record 'accessMode') -in @('reused','rebuilt')
    if (-not $attempt) { if ($isMap) { $excludedMapEventCount++ }; continue }
    $coveredAttempts[$attempt] = $record
    if ($isMap) { $mapEventCount++ }
    if ([string](Get-Value $record 'accessMode') -eq 'full-scan') { $declaredScans.Add($record) }
}

$scanEvents = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$targetedSearchCount = 0
$excludedCommandCount = 0
$unclassifiedCommandCount = 0
$attemptId = ''; $threadId = ''; $segment = 0
if (Test-Path -LiteralPath $Path -PathType Leaf) {
    # Stream only command and boundary records; do not materialize provider output.
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -notmatch 'ecosystem-workflow-run|thread.started|command_execution') { continue }
        try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $type = [string](Get-Value $record 'type')
        if ($type -eq 'ecosystem-workflow-run') { $attemptId=[string](Get-Value $record 'attemptId'); $threadId=''; $segment++; continue }
        if ($type -eq 'thread.started') { $threadId=[string](Get-Value $record 'thread_id'); continue }
        if ($type -ne 'item.completed') { continue }
        $item = Get-Value $record 'item' $null
        if ([string](Get-Value $item 'type') -ne 'command_execution') { continue }
        $command = [string](Get-Value $item 'command')
        # Cheap discovery only; the parser below decides actual scope and ignores
        # words in comments/strings. This also bounds legacy exclusion counts.
        if ($command -notmatch '(?i)(\brg\b[^\r\n]*--files|\bls-files\b|\b(Get-ChildItem|gci|dir|ls)\b[^\r\n]*(?:-Recurse|-r\b|/s)|\bfind\s|\bfindstr\s)') { continue }
        $recordAttempt = [string](Get-Value $record 'attemptId' $attemptId)
        $itemId = [string](Get-Value $item 'id')
        if (-not $itemId) { $unclassifiedCommandCount++; continue }
        $scope = if ($recordAttempt) { $recordAttempt } else { "legacy-$segment" }
        $identity = @($scope,$threadId,$itemId) | ConvertTo-Json -Compress
        if (-not $seen.Add($identity)) { continue }
        if (-not $recordAttempt -or -not $coveredAttempts.ContainsKey($recordAttempt)) { $excludedCommandCount++; continue }
        $kind = Get-EnumerationKind -Command $command
        if ($kind -eq 'targeted') { $targetedSearchCount++; continue }
        if ($kind -eq 'unclassified') { $unclassifiedCommandCount++; continue }
        if ($kind -ne 'full-scan') { continue }
        $telemetry = $coveredAttempts[$recordAttempt]
        $scanEvents.Add([pscustomobject]@{
            schemaVersion=1; metricLevel='knowledge'; eventType='knowledge-access'; eventId=$null
            timestampUtc=[string](Get-Value $record 'timestampUtc'); attemptId=$recordAttempt
            agentId=[string](Get-Value $telemetry 'agentId' 'unknown'); sourceKind='repository-map'
            accessMode='full-scan'; sourceId='transcript-scan'; status='succeeded'; evidenceKind='observed'
            detail='One completed, unfiltered repository enumeration in an attempt with knowledge telemetry.'
        })
    }
}
[pscustomobject]@{
    Events=@($scanEvents); FullScanCount=$scanEvents.Count+$declaredScans.Count
    MapEventCount=$mapEventCount; ExcludedMapEventCount=$excludedMapEventCount
    CoveredAttemptCount=$coveredAttempts.Count; TargetedSearchCount=$targetedSearchCount
    ExcludedCommandCount=$excludedCommandCount; UnclassifiedCommandCount=$unclassifiedCommandCount
}
