[CmdletBinding()]
param([string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) '.test-output/repository-knowledge-map'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetFullPath($OutputRoot)) ([guid]::NewGuid().ToString('N'))
$workspace = Join-Path $root 'repository'
$maps = Join-Path $root 'maps'
New-Item -ItemType Directory -Path (Join-Path $workspace 'src/App'),(Join-Path $workspace 'src/Core'),(Join-Path $workspace 'docs') -Force | Out-Null
& git -C $workspace init -b main | Out-Null
& git -C $workspace config user.email 'map-test@example.invalid'
& git -C $workspace config user.name 'Map Test'
Set-Content -LiteralPath (Join-Path $workspace 'README.md') -Value '# Fixture'
Set-Content -LiteralPath (Join-Path $workspace 'docs/ARCHITECTURE.md') -Value '# Architecture'
Set-Content -LiteralPath (Join-Path $workspace 'src/Core/Core.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="Example.Package" Version="1.0.0" /></ItemGroup></Project>'
Set-Content -LiteralPath (Join-Path $workspace 'src/App/App.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><ProjectReference Include="../Core/Core.csproj" /></ItemGroup></Project>'
Set-Content -LiteralPath (Join-Path $workspace 'src/App/Program.cs') -Value 'internal static class Program { private static void Main() {} }'
& git -C $workspace add .
& git -C $workspace commit -m 'fixture' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Fixture commit failed.' }

$first = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
$map = Get-Content -LiteralPath $first.MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($first.Reused -or [int]$map.summary.fileCount -ne 5 -or [int]$map.summary.componentCount -ne 4) { throw 'Initial repository map counts are incorrect.' }
if (@($map.edges | Where-Object { [string]$_.kind -eq 'references' }).Count -ne 1) { throw 'Project-reference edge was not indexed.' }
if ($map.recommendedStart -notcontains 'docs/ARCHITECTURE.md' -or $map.entryPoints -notcontains 'src/App/Program.cs') { throw 'Repository map omitted recommended architecture or entry-point paths.' }

$second = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
if (-not $second.Reused -or [string]$second.SourceFingerprint -ne [string]$first.SourceFingerprint) { throw 'Unchanged repository map was rebuilt.' }

$staleMap = Get-Content -LiteralPath $second.MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$staleMap.generatorVersion = '0.9.0'
Set-Content -LiteralPath $second.MapPath -Value ($staleMap | ConvertTo-Json -Depth 20) -Encoding UTF8
$regenerated = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
if ($regenerated.Reused -or [string](Get-Content -LiteralPath $regenerated.MapPath -Raw -Encoding UTF8 | ConvertFrom-Json).generatorVersion -ne '1.0.0') { throw 'A stale generator version was reused.' }

Set-Content -LiteralPath (Join-Path $workspace 'README.md') -Value '# Changed fixture'
$trackedChange = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
if ($trackedChange.Reused -or [string]$trackedChange.SourceFingerprint -eq [string]$regenerated.SourceFingerprint -or [int]$trackedChange.FileCount -ne 5) { throw 'A content-only tracked-file change did not invalidate the map.' }

Set-Content -LiteralPath (Join-Path $workspace 'src/Core/NewService.cs') -Value 'internal sealed class NewService {}'
$third = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
if ($third.Reused -or [string]$third.SourceFingerprint -eq [string]$trackedChange.SourceFingerprint -or [int]$third.FileCount -ne 6) { throw 'Dirty repository change did not invalidate the map.' }

Set-Content -LiteralPath (Join-Path $workspace 'src/Core/NewService.cs') -Value 'internal sealed class RenamedService {}'
$fourth = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
if ($fourth.Reused -or [string]$fourth.SourceFingerprint -eq [string]$third.SourceFingerprint -or [string]$fourth.MapPath -eq [string]$third.MapPath) { throw 'A content-only untracked-file change did not create a new content-addressed map.' }

# A Git tree can contain names that are legal Git-relative paths but illegal
# Windows paths. The mapper must not pass those identifiers to System.IO.Path.
$invalidPathBlob = 'repository-map-invalid-path' | & git -C $workspace hash-object -w --stdin
if ($LASTEXITCODE -ne 0) { throw 'Fixture blob creation failed.' }
& git -C $workspace config core.protectNTFS false
if ($LASTEXITCODE -ne 0) { throw 'Fixture NTFS protection override failed.' }
& git -C $workspace update-index --add --cacheinfo "100644,$($invalidPathBlob.Trim()),src/invalid:entry.cs"
if ($LASTEXITCODE -ne 0) { throw 'Fixture index update failed.' }
& git -C $workspace commit -m 'add git-only invalid Windows path' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Fixture invalid-path commit failed.' }
$invalidPathMap = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-RepositoryKnowledgeMap.ps1') -RepositoryId 'fixture-repository' -Workspace $workspace -OutputRoot $maps
$invalidPathDocument = Get-Content -LiteralPath $invalidPathMap.MapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($invalidPathMap.Reused -or $invalidPathDocument.nodes.path -notcontains 'src/invalid:entry.cs') { throw 'Git-relative invalid Windows path was not mapped safely.' }

[pscustomobject]@{ Status='passed'; Checks=7; OutputRoot=$root }
