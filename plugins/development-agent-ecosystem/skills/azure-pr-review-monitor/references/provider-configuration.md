# Provider Configuration

Use the settings manager instead of hand-editing JSON:

```powershell
$settings = "$HOME/.codex/skills/azure-pr-review-monitor/scripts/manage_agent_settings.ps1"
& $settings -Action Show
& $settings -Action Validate
```

Add Azure DevOps:

```powershell
& $settings -Action AddRepository `
  -RepositoryUrl 'https://dev.azure.com/org/project/_git/repository' `
  -Reviewer 'name@company.com'
```

Add GitHub:

```powershell
& $settings -Action AddRepository `
  -RepositoryUrl 'https://github.com/owner/repository' `
  -Reviewer 'github-login'
```

Credential profiles contain no token values. `azure-cli` and `gh-cli` use each CLI's existing authenticated identity. `environment` stores only an environment-variable name:

```powershell
& $settings -Action ConfigureCredential -CredentialProfileId github-default `
  -CredentialMode environment -CredentialEnvironmentVariable GH_TOKEN
```

Configure custom review instructions:

```powershell
& $settings -Action SetReviewPaths `
  -SkillPaths 'C:\review-policy\dotnet-skill' `
  -PromptPaths 'C:\review-policy\team-review.md'
```

MCP is disabled by default. First configure servers in Codex with `codex mcp add`, then explicitly allow read-only servers for automated reviews:

```powershell
codex mcp list --json
& $settings -Action SetMcp -McpMode allowlist -McpServers 'company-docs'
& $settings -Action Validate
```

The runner passes per-invocation overrides that disable every configured MCP server except names in the allowlist. Keep write-capable or untrusted MCP servers disabled for automated review.

Configuration schema: `config.schema.json`. Runtime configuration: `%LOCALAPPDATA%\Codex\azure-pr-review-monitor\config.json`.
