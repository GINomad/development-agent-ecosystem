[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][string] $OutputRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $OutputRoot ('git-boundary-' + [guid]::NewGuid().ToString('N'))
$outer = Join-Path $fixture 'outer'
$nested = Join-Path $outer 'incomplete-clone'
$valid = Join-Path $fixture 'valid'
foreach ($directory in @($outer,$valid,(Join-Path $nested '.git'))) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
foreach ($directory in @($outer,$valid)) {
    $null = @(& git -C $directory init 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize Git boundary fixture.' }
    & git -C $directory remote add origin 'https://example.invalid/expected.git'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to set fixture origin.' }
}
$sourcePath = Join-Path $Root 'scripts/Provision-TaskWorkspace.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($name in @('Assert-TaskWorkspaceGitRoot','Invoke-TaskWorkspaceGit')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $function) { throw "Missing production Git boundary function: $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
# Reproduce Git's dangerous ancestor discovery without ever mutating the real repo.
$discovered = ([string](& git -C $nested rev-parse --show-toplevel)).Trim()
if (-not [IO.Path]::GetFullPath($discovered).Equals([IO.Path]::GetFullPath($outer), [StringComparison]::OrdinalIgnoreCase)) { throw 'Boundary fixture did not reproduce ancestor discovery.' }
$rejected = $false
try { Invoke-TaskWorkspaceGit -WorkingDirectory $nested -Arguments @('remote','set-url','origin','https://example.invalid/wrong.git') | Out-Null }
catch { $rejected = $_.Exception.Message -match 'refusing parent-repository fallback' }
if (-not $rejected) { throw 'Incomplete clone was allowed to mutate its parent repository.' }
if (([string](& git -C $outer remote get-url origin)).Trim() -ne 'https://example.invalid/expected.git') { throw 'Parent origin changed.' }
$validOrigin = Invoke-TaskWorkspaceGit -WorkingDirectory $valid -Arguments @('remote','get-url','origin')
if ([string]$validOrigin -ne 'https://example.invalid/expected.git') { throw 'Valid clone was rejected.' }
$savedGitDir = [Environment]::GetEnvironmentVariable('GIT_DIR','Process')
$savedWorkTree = [Environment]::GetEnvironmentVariable('GIT_WORK_TREE','Process')
try {
    $env:GIT_DIR = Join-Path $outer '.git'
    $env:GIT_WORK_TREE = $outer
    $redirectRejected = $false
    try { Invoke-TaskWorkspaceGit -WorkingDirectory $valid -Arguments @('remote','set-url','origin','https://example.invalid/wrong.git') | Out-Null }
    catch { $redirectRejected = $_.Exception.Message -match 'refusing parent-repository fallback' }
    if (-not $redirectRejected) { throw 'Inherited Git root redirection was accepted.' }
} finally {
    if ([string]::IsNullOrEmpty($savedGitDir)) { Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue }
    else { $env:GIT_DIR = $savedGitDir }
    if ([string]::IsNullOrEmpty($savedWorkTree)) { Remove-Item Env:GIT_WORK_TREE -ErrorAction SilentlyContinue }
    else { $env:GIT_WORK_TREE = $savedWorkTree }
}
if (([string](& git -C $outer remote get-url origin)).Trim() -ne 'https://example.invalid/expected.git') { throw 'Inherited environment changed the parent origin.' }
[pscustomobject]@{ Passed=$true; ParentFallbackRejected=$true; RedirectedEnvironmentRejected=$true; ValidCloneAccepted=$true }
