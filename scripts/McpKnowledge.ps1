Set-StrictMode -Version Latest

function Assert-McpSourcePath {
    param([Parameter(Mandatory)][string] $Path)
    $item = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force -ErrorAction Stop
    while ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'MCP sources must not traverse reparse points.' }
        $parent = Split-Path -Parent $item.FullName
        if (-not $parent -or $parent -eq $item.FullName) { break }
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
}

function Get-McpKnowledgeSources {
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)][string] $AgentId,
        [string[]] $RepositoryIds = @(), [string] $CodexHome)
    $agent = @($Config.agents | Where-Object { [string]$_.id -eq $AgentId }) | Select-Object -First 1
    if (-not $agent) { throw "Unknown MCP role '$AgentId'." }
    $sources = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-Source([string]$Id, [string]$Kind, [string]$Path) {
        $full = [IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or -not $seen.Add($full)) { return }
        Assert-McpSourcePath -Path $full
        $sources.Add([ordered]@{ id=$Id; kind=$Kind; path=$full; sha256=(Get-EcosystemFileSha256 -Path $full) })
    }
    $roots = @([pscustomobject]@{id='global'; path=(Resolve-EcosystemPath -Value ([string]$Config.knowledge.technicalRoot) -Config $Config -CodexHome $CodexHome)})
    foreach ($project in @($Config.projects | Where-Object { $_.enabled -and @($_.repositoryIds | Where-Object { $_ -in $RepositoryIds }).Count })) {
        $roots += [pscustomobject]@{id=('project/'+[string]$project.id); path=(Resolve-EcosystemPath -Value ([string]$project.domainKnowledgeRoot) -Config $Config -CodexHome $CodexHome)}
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.path -PathType Container)) { continue }
        Assert-McpSourcePath -Path $root.path
        foreach ($file in @(Get-ChildItem -LiteralPath $root.path -Recurse -File | Where-Object { $_.Extension -in @('.md','.txt','.json','.yaml','.yml') } | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($root.path.TrimEnd('\','/').Length + 1).Replace('\','/')
            # Skills are supplied only through the role/project skill allowlist below.
            if ($relative -match '(^|/)skills/') { continue }
            Add-Source ($root.id+'/'+$relative) 'knowledge' $file.FullName
        }
    }
    $skillPaths = @($agent.skillPaths | ForEach-Object { Resolve-EcosystemPath -Value ([string]$_) -Config $Config -CodexHome $CodexHome })
    $skillPaths += @(& (Join-Path $PSScriptRoot 'Get-ProjectSkillPaths.ps1') -Config $Config -AgentId $AgentId -RepositoryIds $RepositoryIds -CodexHome $CodexHome)
    foreach ($path in $skillPaths) {
        $name = Split-Path -Leaf (Split-Path -Parent $path)
        $index = $sources.Count
        Add-Source ('skill/'+$name+'/'+$index) 'skill' $path
    }
    @($sources)
}
