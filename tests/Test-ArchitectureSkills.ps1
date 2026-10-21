[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'scripts/AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath (Join-Path $Root 'config/agents.json')
$skills = @('architecture-and-pattern-selection','design-patterns','develop-angular','api-and-interface-design','domain-modeling','architecture-decision-records','data-access-and-database-design','messaging-and-reliability','testing-and-observability')
foreach ($id in @('requirements_analyst','developer','reviewer','review_verifier')) {
    $agent = @($config.agents | Where-Object { $_.id -eq $id })[0]
    $toml = New-AgentToml -Agent $agent -Config $config
    foreach ($name in $skills) {
        $relative = 'plugins/development-agent-ecosystem/skills/' + $name + '/SKILL.md'
        if (-not @($agent.skillPaths | Where-Object { $_.Replace('\','/').EndsWith($relative) }).Count) { throw "Missing shared skill $name for $id" }
        $resolved = Resolve-EcosystemPath -Value ('${REPO_ROOT}/' + $relative) -Config $config
        # Generation must expose the shared skill to the installed role too.
        if (-not $toml.Contains((ConvertTo-TomlString $resolved))) { throw "Generated role omits $name for $id" }
    }
}
$fixture = Join-Path $Root ('.test-output/project-skill-selection-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    foreach ($projectId in @('a','b')) {
        $path = Join-Path $fixture ($projectId + '/skills/' + $projectId + '-domain/SKILL.md')
        Write-Utf8NoBom -Path $path -Content ("---`nname: " + $projectId + "-domain`ndescription: Synthetic local domain.`n---`n")
    }
    $fixtureConfig = $config | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $fixtureConfig.projects = @(
        [pscustomobject]@{id='a';enabled=$true;repositoryIds=@('repo-a');domainKnowledgeRoot=(Join-Path $fixture 'a')},
        [pscustomobject]@{id='b';enabled=$true;repositoryIds=@('repo-b');domainKnowledgeRoot=(Join-Path $fixture 'b')}
    )
    $resolver = Join-Path $Root 'scripts/Get-ProjectSkillPaths.ps1'
    $selected = @(& $resolver -Config $fixtureConfig -AgentId reviewer -RepositoryIds repo-a)
    if ($selected.Count -ne 1 -or $selected[0] -notlike '*a-domain*') { throw 'Local domain selection crossed repository boundaries.' }
    if (@(& $resolver -Config $fixtureConfig -AgentId reviewer -RepositoryIds missing).Count) { throw 'Unknown repositories received local skills.' }
    if (@(& $resolver -Config $fixtureConfig -AgentId pipeline_monitor -AllProjects).Count) { throw 'Unrelated role received domain skills.' }
    if (@(& $resolver -Config $fixtureConfig -AgentId requirements_analyst -AllProjects).Count -ne 2) { throw 'Local role installation omitted project skills.' }
    $fixtureConfig.projects[1].enabled = $false
    if (@(& $resolver -Config $fixtureConfig -AgentId developer -AllProjects).Count -ne 1) { throw 'Disabled project skills were exposed.' }
    # Exercise the real context issuer, including deterministic reuse and local
    # source changes. No product checkout or model is launched.
    $contextConfig = $config | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $contextConfig.runtime.stateRoot = Join-Path $fixture 'state'
    $contextConfig.projects[0].domainKnowledgeRoot = Join-Path $fixture 'a'
    $contextConfig.projects[1].domainKnowledgeRoot = Join-Path $fixture 'b'
    $contextConfigPath = Join-Path $fixture 'agents.json'
    Write-Utf8NoBom -Path $contextConfigPath -Content ($contextConfig | ConvertTo-Json -Depth 100)
    Write-Utf8NoBom -Path (Join-Path $fixture 'agents.local.json') -Content 'Invalid adjacent local file must not override an explicit fixture.'
    if ((Resolve-EcosystemConfigPath -ConfigPath $contextConfigPath) -ne [IO.Path]::GetFullPath($contextConfigPath)) { throw 'Explicit configuration was silently replaced.' }
    $taskId = 'project-skills-' + [guid]::NewGuid().ToString('N')
    $task = & (Join-Path $Root 'scripts/New-AgentTask.ps1') -TaskId $taskId -TaskSelector synthetic-project-skills -Mode manual -RepositoryIds azure-planningspace-planningspace -ConfigPath $contextConfigPath
    & (Join-Path $Root 'scripts/Update-AgentContextPack.ps1') -TaskId $taskId -RecipientAgentId requirements_analyst -ConfigPath $contextConfigPath | Out-Null
    $packPath = Join-Path $task.TaskRoot 'context-pack.json'
    $pack = Get-Content -LiteralPath $packPath -Raw | ConvertFrom-Json
    $localSources = @($pack.sources | Where-Object { $_.reason -like 'Local project skill matched*' })
    if ($localSources.Count -ne 1 -or $localSources[0].location -notlike '*a-domain*' -or 'a-domain' -notin @($pack.engineeringGuidance.selectedSkills) -or 'b-domain' -in @($pack.engineeringGuidance.selectedSkills)) { throw 'Context issuer mixed local project skills.' }
    $firstHash = Get-EcosystemFileSha256 -Path $packPath
    & (Join-Path $Root 'scripts/Update-AgentContextPack.ps1') -TaskId $taskId -RecipientAgentId requirements_analyst -ConfigPath $contextConfigPath | Out-Null
    if ((Get-EcosystemFileSha256 -Path $packPath) -ne $firstHash) { throw 'Unchanged project context was not reused.' }
    $localPath = Join-Path $fixture 'a/skills/a-domain/SKILL.md'
    Write-Utf8NoBom -Path $localPath -Content ((Get-Content -LiteralPath $localPath -Raw) + 'Updated verified synthetic rule.')
    & (Join-Path $Root 'scripts/Update-AgentContextPack.ps1') -TaskId $taskId -RecipientAgentId requirements_analyst -ConfigPath $contextConfigPath | Out-Null
    $changedPack = Get-Content -LiteralPath $packPath -Raw | ConvertFrom-Json
    $changedSource = @($changedPack.sources | Where-Object { $_.reason -like 'Local project skill matched*' })[0]
    if ($changedSource.revision -eq $localSources[0].revision -or $changedSource.revision -ne (Get-EcosystemFileSha256 -Path $localPath)) { throw 'Changed local rule did not invalidate its context fingerprint.' }
    $publicationRoot = Join-Path $fixture 'publication'
    New-Item -ItemType Directory -Path $publicationRoot -Force | Out-Null
    & git -C $publicationRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize publication test.' }
    $privateFile = Join-Path $publicationRoot 'knowledge/managed/projects/synthetic/skills/domain/SKILL.md'
    Write-Utf8NoBom -Path $privateFile -Content 'synthetic private knowledge'
    & git -C $publicationRoot add -- knowledge
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage negative fixture.' }
    $rejected = $false
    try { & (Join-Path $Root 'scripts/Test-PublicationBoundary.ps1') -Root $publicationRoot | Out-Null } catch { $rejected = $_.Exception.Message -like 'Publication tree contains*' }
    if (-not $rejected) { throw 'Publication guard accepted private staged knowledge.' }
    & git -C $publicationRoot -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m synthetic-private-history
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit negative history fixture.' }
    & git -C $publicationRoot rm -r --cached --quiet knowledge
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $privateFile)) { throw 'Untracking did not preserve local knowledge.' }
    & (Join-Path $Root 'scripts/Test-PublicationBoundary.ps1') -Root $publicationRoot | Out-Null
    & git -C $publicationRoot -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m synthetic-current-tree-clean
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit clean-tip fixture.' }
    $historyRejected = $false
    try { & (Join-Path $Root 'scripts/Test-PublicationBoundary.ps1') -Root $publicationRoot -Revision HEAD -History | Out-Null } catch { $historyRejected = $_.Exception.Message -like 'Publication tree contains*' }
    if (-not $historyRejected) { throw 'A clean tip with private ancestors passed the history guard.' }
} finally {
    if ([IO.Path]::GetFullPath($fixture).StartsWith([IO.Path]::GetFullPath((Join-Path $Root '.test-output')) + [IO.Path]::DirectorySeparatorChar)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
[pscustomobject]@{Passed=$true;SharedSkills=$skills.Count;Roles=4;ProjectIsolation=$true;PublicationNegativeControl=$true}
