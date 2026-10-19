[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $RepositoryId,
    [Parameter(Mandatory)][string] $Workspace,
    [Parameter(Mandatory)][string] $OutputRoot,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$generatorVersion = '1.0.0'

function Invoke-GitMapCommand {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& git -C $script:resolvedWorkspace @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    @($output | ForEach-Object { [string]$_ })
}

function Get-MapHash {
    param([Parameter(Mandatory)][string] $Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join @($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

function Get-FilePurpose {
    param([Parameter(Mandatory)][string] $Path)
    if ($Path -match '(?i)(^|/)(test|tests|spec|specs)(/|$)|(?i)(test|tests|spec)\.[^/]+$') { return 'test' }
    if ($Path -match '(?i)(^|/)(docs?|documentation)(/|$)|\.(md|rst|txt)$') { return 'documentation' }
    if ($Path -match '(?i)(\.sln|\.csproj|\.fsproj|package\.json|pyproject\.toml|Cargo\.toml|go\.mod)$') { return 'manifest' }
    if ($Path -match '(?i)(^|/)(config|configuration)(/|$)|\.(json|ya?ml|toml|props|targets)$') { return 'configuration' }
    if ($Path -match '(?i)\.(cs|fs|vb|js|jsx|ts|tsx|py|go|rs|java|kt|cpp|c|h)$') { return 'source' }
    return 'asset'
}

function Get-RepositoryRelativeDirectory {
    param([Parameter(Mandatory)][string] $Path)
    # Git tree entries use POSIX separators and may contain characters that are
    # not valid in a Windows filesystem path. Treat them as Git-relative IDs.
    $normalized = $Path.Replace('\','/')
    $separatorIndex = $normalized.LastIndexOf('/')
    if ($separatorIndex -lt 0) { return '' }
    return $normalized.Substring(0, $separatorIndex)
}

function Get-NormalizedRelativePath {
    param([Parameter(Mandatory)][string] $BaseDirectory, [Parameter(Mandatory)][string] $Candidate)
    $absolute = [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Candidate))
    [IO.Path]::GetRelativePath($script:resolvedWorkspace, $absolute).Replace('\','/')
}

$resolvedWorkspace = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path)
$repositoryRoot = (Invoke-GitMapCommand -Arguments @('rev-parse','--show-toplevel') | Select-Object -First 1).Trim()
if ([IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') -ne $resolvedWorkspace.TrimEnd('\')) {
    throw "Workspace must be the Git repository root: $resolvedWorkspace"
}

$revision = (Invoke-GitMapCommand -Arguments @('rev-parse','HEAD') | Select-Object -First 1).Trim()
$status = @(Invoke-GitMapCommand -Arguments @('status','--porcelain=v1','--untracked-files=all'))
$dirtyEvidence = @()
if ($status.Count) {
    foreach ($trackedFile in @(Invoke-GitMapCommand -Arguments @('diff','--name-only','HEAD','--'))) {
        $trackedPath = Join-Path $resolvedWorkspace $trackedFile
        $trackedHash = if (Test-Path -LiteralPath $trackedPath -PathType Leaf) { (Get-FileHash -LiteralPath $trackedPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'deleted' }
        $dirtyEvidence += "tracked:$($trackedFile.Replace('\','/')):$trackedHash"
    }
    foreach ($untrackedFile in @(Invoke-GitMapCommand -Arguments @('ls-files','--others','--exclude-standard'))) {
        $untrackedPath = Join-Path $resolvedWorkspace $untrackedFile
        if (Test-Path -LiteralPath $untrackedPath -PathType Leaf) {
            $dirtyEvidence += "untracked:$($untrackedFile.Replace('\','/')):$((Get-FileHash -LiteralPath $untrackedPath -Algorithm SHA256).Hash.ToLowerInvariant())"
        }
    }
}
$sourceFingerprint = Get-MapHash -Text (($revision + [Environment]::NewLine + ($status -join [Environment]::NewLine) + [Environment]::NewLine + ($dirtyEvidence -join [Environment]::NewLine)).Trim())
$resolvedOutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (-not (Test-Path -LiteralPath $resolvedOutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $resolvedOutputRoot -Force | Out-Null }
$mapPath = Join-Path $resolvedOutputRoot "$RepositoryId-$sourceFingerprint.json"

if (-not $Force -and (Test-Path -LiteralPath $mapPath -PathType Leaf)) {
    try { $existing = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $existing = $null }
    if ($existing -and [string]$existing.schemaVersion -eq '1.0.0' -and [string]$existing.generatorVersion -eq $generatorVersion -and [string]$existing.sourceFingerprint -eq $sourceFingerprint) {
        return [pscustomobject]@{ RepositoryId=$RepositoryId; MapPath=$mapPath; Revision=$revision; SourceFingerprint=$sourceFingerprint; Reused=$true; FileCount=[int]$existing.summary.fileCount; ComponentCount=[int]$existing.summary.componentCount }
    }
}

$excluded = '(?i)(^|/)(\.git|node_modules|packages|bin|obj|dist|build|coverage|\.runtime|\.test-output)(/|$)'
$files = @(Invoke-GitMapCommand -Arguments @('ls-files','-co','--exclude-standard') | ForEach-Object { $_.Replace('\','/') } | Where-Object { $_ -and $_ -notmatch $excluded } | Sort-Object -Unique)
$directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $files) {
    $directory = Get-RepositoryRelativeDirectory -Path $file
    while ($directory) {
        [void]$directories.Add($directory)
        $parent = Get-RepositoryRelativeDirectory -Path $directory
        if ($parent -eq $directory) { break }
        $directory = $parent
    }
}

$nodes = [Collections.Generic.List[object]]::new()
$edges = [Collections.Generic.List[object]]::new()
$nodes.Add([ordered]@{ id='repository'; kind='repository'; path=''; purpose='repository-root' })
foreach ($directory in @($directories | Sort-Object)) {
    $nodes.Add([ordered]@{ id="directory:$directory"; kind='directory'; path=$directory; purpose='source-tree' })
    $parent = Get-RepositoryRelativeDirectory -Path $directory
    $edges.Add([ordered]@{ from=if($parent){"directory:$parent"}else{'repository'}; to="directory:$directory"; kind='contains' })
}
foreach ($file in $files) {
    $nodes.Add([ordered]@{ id="file:$file"; kind='file'; path=$file; purpose=(Get-FilePurpose -Path $file) })
    $directory = Get-RepositoryRelativeDirectory -Path $file
    $edges.Add([ordered]@{ from=if($directory){"directory:$directory"}else{'repository'}; to="file:$file"; kind='contains' })
}

$components = [Collections.Generic.List[object]]::new()
$manifestPatterns = '(?i)(\.sln|\.csproj|\.fsproj|package\.json|pyproject\.toml|Cargo\.toml|go\.mod)$'
foreach ($manifest in @($files | Where-Object { $_ -match $manifestPatterns })) {
    $manifestPath = Join-Path $resolvedWorkspace $manifest
    $kind = [IO.Path]::GetFileName($manifest)
    $name = [IO.Path]::GetFileNameWithoutExtension($manifest)
    $projectReferences = [Collections.Generic.List[string]]::new()
    $packageDependencies = [Collections.Generic.List[string]]::new()
    if ($manifest -match '(?i)\.(csproj|fsproj)$') {
        try {
            [xml]$project = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
            foreach ($reference in @($project.Project.ItemGroup.ProjectReference)) {
                if ($reference.Include) { $projectReferences.Add((Get-NormalizedRelativePath -BaseDirectory (Split-Path -Parent $manifestPath) -Candidate ([string]$reference.Include))) }
            }
            foreach ($reference in @($project.Project.ItemGroup.PackageReference)) { if ($reference.Include) { $packageDependencies.Add([string]$reference.Include) } }
        } catch { }
    }
    elseif ($manifest -match '(?i)\.sln$') {
        foreach ($line in @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)) {
            $match = [regex]::Match([string]$line, '(?i)Project\("[^"]+"\)\s*=\s*"[^"]+",\s*"(?<path>[^"]+\.(?:csproj|fsproj|vbproj))"')
            if ($match.Success) { $projectReferences.Add((Get-NormalizedRelativePath -BaseDirectory (Split-Path -Parent $manifestPath) -Candidate $match.Groups['path'].Value)) }
        }
    }
    elseif ([IO.Path]::GetFileName($manifest) -ieq 'package.json') {
        try {
            $package = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($package.name) { $name = [string]$package.name }
            foreach ($group in @('dependencies','devDependencies','peerDependencies')) {
                if ($package.PSObject.Properties[$group] -and $package.$group) { foreach ($property in $package.$group.PSObject.Properties) { $packageDependencies.Add([string]$property.Name) } }
            }
        } catch { }
    }
    $componentId = "component:$manifest"
    $components.Add([ordered]@{ id=$componentId; name=$name; kind=$kind; manifest=$manifest; projectReferences=@($projectReferences | Sort-Object -Unique); packageDependencies=@($packageDependencies | Sort-Object -Unique) })
    foreach ($reference in @($projectReferences | Sort-Object -Unique)) { $edges.Add([ordered]@{ from="file:$manifest"; to="file:$reference"; kind='references' }) }
}

foreach ($topLevelDirectory in @($directories | Where-Object { $_ -notmatch '/' } | Sort-Object)) {
    $components.Add([ordered]@{ id="component:directory:$topLevelDirectory"; name=$topLevelDirectory; kind='directory'; manifest=$topLevelDirectory; projectReferences=@(); packageDependencies=@() })
}

$entryPoints = @($files | Where-Object { $_ -match '(?i)(^|/)(Program\.cs|Startup\.cs|main\.[^.]+|app\.[^.]+|index\.[^.]+|package\.json|[^/]+\.sln)$' } | Select-Object -First 100)
$architectureDocs = @($files | Where-Object { $_ -match '(?i)(^|/)(AGENTS|ARCHITECTURE|DESIGN|README|CONTRIBUTING)\.md$' } | Sort-Object { ([string]$_).Split('/').Count }, { [string]$_ })
$primaryArchitectureDocs = @($architectureDocs | Where-Object { ([string]$_).Split('/').Count -le 2 })
$manifestStart = @($components | Where-Object { [string]$_.kind -ne 'directory' } | ForEach-Object { [string]$_.manifest })
$recommendedStart = @($primaryArchitectureDocs + $manifestStart + $entryPoints | Select-Object -Unique | Select-Object -First 30)

$hintTable = [ordered]@{}
foreach ($file in $files) {
    $terms = @([regex]::Matches($file.ToLowerInvariant(), '[a-z][a-z0-9]{2,}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    foreach ($term in $terms) {
        if (-not $hintTable.Contains($term)) { $hintTable[$term] = [Collections.Generic.List[string]]::new() }
        if ($hintTable[$term].Count -lt 12 -and -not $hintTable[$term].Contains($file)) { $hintTable[$term].Add($file) }
    }
}
$lookupHints = [ordered]@{}
foreach ($term in @($hintTable.Keys | Sort-Object | Select-Object -First 2000)) { $lookupHints[$term] = @($hintTable[$term]) }

$map = [ordered]@{
    schemaVersion = '1.0.0'
    generatorVersion = $generatorVersion
    repositoryId = $RepositoryId
    revision = $revision
    sourceFingerprint = $sourceFingerprint
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    summary = [ordered]@{ fileCount=$files.Count; directoryCount=$directories.Count; componentCount=$components.Count; edgeCount=$edges.Count }
    audit = [ordered]@{ structuralStatus='indexed'; semanticStatus='pending'; instructions='Knowledge Keeper verifies component responsibilities, entry points, ownership boundaries, and cross-component relationships before promoting semantic guidance.' }
    components = @($components)
    entryPoints = @($entryPoints)
    nodes = @($nodes)
    edges = @($edges)
    lookupHints = $lookupHints
    recommendedStart = @($recommendedStart)
}
Write-Utf8NoBomAtomic -Path $mapPath -Content (($map | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

[pscustomobject]@{ RepositoryId=$RepositoryId; MapPath=$mapPath; Revision=$revision; SourceFingerprint=$sourceFingerprint; Reused=$false; FileCount=$files.Count; ComponentCount=$components.Count }
