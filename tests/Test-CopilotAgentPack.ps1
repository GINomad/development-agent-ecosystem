[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$roles = [ordered]@{
    'development-workflow-orchestrator' = 'read,search,agent'
    'development-requirements-analyst' = 'read,search'
    'development-implementer' = 'read,search,edit,execute'
    'development-reviewer' = 'read,search'
    'development-review-verifier' = 'read,search'
    'development-knowledge-keeper' = 'read,search,edit'
    'development-pipeline-monitor' = 'read,search,web'
    'development-health-check' = 'read,search,edit'
}
$directory = Join-Path $Root '.github/agents'
if (@(Get-ChildItem -LiteralPath $directory -File).Count -ne 8) { throw 'Expected eight agents.' }
foreach ($name in $roles.Keys) {
    $text = Get-Content -LiteralPath (Join-Path $directory "$name.agent.md") -Raw
    $match = [regex]::Match($text, '\A---\r?\n(?<header>.*?)\r?\n---\r?\n(?<body>.+)\z', 'Singleline')
    if (-not $match.Success) { throw "Invalid frontmatter: $name" }
    $header = $match.Groups['header'].Value
    $fields = @([regex]::Matches($header, '(?m)^([a-z][a-z-]*):') | ForEach-Object { $_.Groups[1].Value })
    $required = @('name','description','tools','agents','user-invocable','disable-model-invocation')
    if (@($fields | Where-Object { $_ -notin ($required + 'handoffs') }).Count -or
        @($fields | Select-Object -Unique).Count -ne $fields.Count) { throw "Unsupported/duplicate header: $name" }
    foreach ($field in $required) { if ($field -notin $fields) { throw "Missing $field in $name" } }
    if ($header -notmatch "(?m)^name: $([regex]::Escape($name))\r?$") { throw "Invalid name: $name" }
    $description = [regex]::Match($header, '(?m)^description: (.+)').Groups[1].Value | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($description)) { throw "Empty description: $name" }
    $toolJson = [regex]::Match($header, '(?m)^tools: (.+)').Groups[1].Value.Replace("'", '"')
    if ((@($toolJson | ConvertFrom-Json) -join ',') -ne $roles[$name]) { throw "Role tool boundary changed: $name" }
    $agentJson = [regex]::Match($header, '(?m)^agents: (.+)').Groups[1].Value.Replace("'", '"')
    $delegates = @($agentJson | ConvertFrom-Json)
    $wanted = if ($name -eq 'development-workflow-orchestrator') { @($roles.Keys | Where-Object { $_ -ne $name } | Sort-Object) } else { @() }
    if ((($delegates | Sort-Object) -join ',') -ne ($wanted -join ',')) { throw "Delegation boundary changed: $name" }
    foreach ($handoff in [regex]::Matches($header, '(?m)^    agent: (.+)')) {
        if ($handoff.Groups[1].Value.Trim() -notin $roles.Keys) { throw "Unknown handoff: $name" }
    }
    if ([regex]::Matches($header, '(?m)^    agent:').Count -ne [regex]::Matches($header, '(?m)^    send: false\r?$').Count) {
        throw "Every handoff must require manual submission: $name"
    }
    foreach ($contract in @('standalone GitHub Copilot','Do not run PowerShell','~/.copilot/development-agent-knowledge/','Preserve unrelated')) {
        if (-not $text.Contains($contract)) { throw "Missing contract '$contract': $name" }
    }
    if ($text -match 'Publish-AgentOutcome|\$\{REPO_ROOT\}|~/.claude/|review-verification.schema.json') { throw "Runtime dependency: $name" }
}
$skills = @('apply-engineering-principles','develop-dotnet','develop-javascript-typescript','develop-react','verify-review-findings')
if (@(Get-ChildItem (Join-Path $Root '.github/skills') -Directory).Count -ne 5) { throw 'Expected five skills.' }
foreach ($skill in $skills) {
    $text = Get-Content (Join-Path $Root ".github/skills/$skill/SKILL.md") -Raw
    if ($text -notmatch "(?m)^name: $([regex]::Escape($skill))\r?$" -or $text -notmatch '(?m)^description: .+') { throw "Invalid skill: $skill" }
    if ($text -match 'Publish-AgentOutcome|review-verification.schema.json|\$\{REPO_ROOT\}') { throw "Runtime skill dependency: $skill" }
    if ($skill -ne 'verify-review-findings') {
        $canonical = Get-Content (Join-Path $Root "plugins/development-agent-ecosystem/skills/$skill/SKILL.md") -Raw
        if ($text.Replace([string][char]13,'') -cne $canonical.Replace([string][char]13,'')) { throw "Portable skill drift: $skill" }
    }
}
if (@(Get-ChildItem (Join-Path $Root '.github/skills') -Recurse -Filter openai.yaml).Count) { throw 'Unexpected Codex metadata.' }
$routing = Get-Content (Join-Path $Root '.github/copilot-instructions.md') -Raw
foreach ($marker in @('<!-- development-agent-standalone:start -->','<!-- development-agent-standalone:end -->')) {
    if ([regex]::Matches($routing,[regex]::Escape($marker)).Count -ne 1) { throw "Invalid marker: $marker" }
}
$installer = Get-Content (Join-Path $Root 'INSTALL-COPILOT-VSCODE-AGENTS.md') -Raw
foreach ($name in $roles.Keys) {
    if (-not $routing.Contains($name) -or -not $installer.Contains(".github/agents/$name.agent.md")) { throw "Missing manifest/routing: $name" }
}
foreach ($skill in $skills) {
    if (-not $installer.Contains(".github/skills/$skill/SKILL.md")) { throw "Missing installer skill: $skill" }
}
[pscustomobject]@{ Status = 'passed'; Agents = 8; Skills = 5; LiveCopilot = 'not-tested' }
