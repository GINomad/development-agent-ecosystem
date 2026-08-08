# Multi-provider PR Review Agent

This package installs a local Codex agent for changed pull requests assigned to you in Azure DevOps, GitHub, or GitHub Enterprise. It reviews the complete PR diff and provides a loopback-only interactive dashboard. Findings are never published automatically.

## Dependencies

```powershell
winget install --exact --id Git.Git
winget install --exact --id Microsoft.AzureCLI  # Azure DevOps only
winget install --exact --id GitHub.cli          # GitHub only
az extension add --name azure-devops            # Azure DevOps only
```

Install/sign in to Codex separately. CLI credential stores are recommended:

```powershell
az login --allow-no-subscriptions
gh auth login --web
codex login status
```

For unattended credentials, set `AZURE_DEVOPS_EXT_PAT`, `GH_TOKEN`, or `GH_ENTERPRISE_TOKEN` as a user environment variable and select `environment` mode. Token values never belong in `config.json`.

## Install

Azure DevOps:

```powershell
.\install.ps1 -RepositoryUrl 'https://dev.azure.com/org/project/_git/repository' -Reviewer 'name@company.com'
```

GitHub:

```powershell
.\install.ps1 -RepositoryUrl 'https://github.com/owner/repository' -Reviewer 'github-login'
```

Multiple repositories:

```powershell
.\install.ps1 `
  -RepositoryUrl 'https://dev.azure.com/org/project/_git/repo-one','https://github.com/owner/repo-two' `
  -Reviewer 'name@company.com','github-login'
```

## Settings

```powershell
$settings = "$HOME/.codex/skills/azure-pr-review-monitor/scripts/manage_agent_settings.ps1"
& $settings -Action Show
& $settings -Action AddRepository -RepositoryUrl 'https://github.com/owner/another-repo' -Reviewer 'github-login'
& $settings -Action ConfigureCredential -CredentialProfileId github-default -CredentialMode environment -CredentialEnvironmentVariable GH_TOKEN
& $settings -Action SetReviewPaths -SkillPaths 'C:\review\skills' -PromptPaths 'C:\review\team.md'
& $settings -Action SetMcp -McpMode allowlist -McpServers 'company-docs'
& $settings -Action Validate
```

MCP is disabled for automated reviews by default. Configure servers with `codex mcp add`, then allowlist only read-only servers. The runner disables every non-allowlisted configured MCP server for each Codex invocation.

## Run

```powershell
$runner = "$HOME/.codex/skills/azure-pr-review-monitor/scripts/run_pr_review_monitor.ps1"
& $runner -Mode Manual -DryRun
& $runner -Mode Manual
& "$HOME/.codex/skills/azure-pr-review-monitor/scripts/open_review_dashboard.ps1"
```

Configuration and reports live under `%LOCALAPPDATA%\Codex\azure-pr-review-monitor`. Scheduled tasks poll hourly, run daily at 11:00, and keep the dashboard available after logon.
