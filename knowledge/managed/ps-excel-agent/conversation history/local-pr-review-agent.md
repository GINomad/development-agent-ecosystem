# Local PR Review Agent

Updated: 2026-08-04

## Installation

- Skill: `%USERPROFILE%\.codex\skills\azure-pr-review-monitor`
- Runtime data: `%LOCALAPPDATA%\Codex\azure-pr-review-monitor`
- Reports: `%LOCALAPPDATA%\Codex\azure-pr-review-monitor\reports`
- Dashboard: `http://127.0.0.1:47831`
- Export: `C:\Repos\AI Knowledge\ps_excel_agent\exports\azure-pr-review-agent.zip`

The historical skill/data folder name remains for backward compatibility. The implementation is provider-neutral.

## Providers

- `azure-devops`: Azure CLI, signed-in identity or environment credential profile.
- `github`: GitHub CLI for GitHub.com and GitHub Enterprise, signed-in identity or environment credential profile.
- Provider-specific discovery, status, clone/fetch, and publication live under `scripts\providers` and return a normalized PR model to the runner.

## Configuration

`config.json` schema version is 2. It contains repositories, credential profiles, review paths, schedule, and MCP policy. It never contains token values.

```powershell
$settings = "$HOME/.codex/skills/azure-pr-review-monitor/scripts/manage_agent_settings.ps1"
& $settings -Action Show
& $settings -Action AddRepository -RepositoryUrl '<url>' -Reviewer '<identity>'
& $settings -Action ConfigureCredential -CredentialProfileId '<id>' -CredentialMode environment -CredentialEnvironmentVariable '<name>'
& $settings -Action SetMcp -McpMode allowlist -McpServers '<read-only-server>'
& $settings -Action Validate
```

MCP is disabled by default. For every Codex invocation, the runner explicitly disables all configured MCP servers except names in the allowlist.

## Schedule

- `Codex PR Review - Updates`: hourly poll.
- `Codex PR Review - Daily`: daily at 11:00 local time.
- `Codex PR Review - Dashboard`: loopback dashboard after logon.

## Verification

- Azure access validation passed against `PlanningSpace/ps-excel-agent`.
- Installed dry run found PR 23280 and then correctly reported it unchanged after v1 state migration.
- GitHub discovery, access validation, and inline publication passed against a local mock CLI contract.
- Dashboard health returns `{"status":"ok","service":"codex-pr-review-dashboard"}`.
- Portable Azure installer passed in isolated install/data roots.

GitHub CLI is not currently installed on this workstation. Install it before adding a real GitHub repository:

```powershell
winget install --exact --id GitHub.cli
gh auth login --web
```
