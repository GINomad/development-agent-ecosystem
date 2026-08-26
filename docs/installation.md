# Installation

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7;
- Codex CLI with plugin and custom-agent support;
- Azure CLI with access to the configured Azure DevOps organization;
- a local working copy of every configured repository.

The current configuration uses Azure CLI at `C:/Program Files/Microsoft SDKs/Azure/CLI2/wbin/az.cmd`. Secrets are not copied into this repository.

For a guided developer-specific installation, give the repository directory to an LLM with filesystem and terminal access and ask it to follow [`SETUP_WITH_LLM.md`](../SETUP_WITH_LLM.md). It must interview the developer, show a redacted preview, and obtain confirmation before installation or external actions.

## 1. Review the shared configuration

Open `config/agents.json` and verify:

- `repositories[].localWorkspace` and the Azure organization, project, repository, and reviewer;
- `taskSources[]` for assigned work items;
- `credentialProfiles[]`, which must contain only CLI or environment authentication strategy, never tokens or passwords;
- `operation.mode`, set to `manual` or `automate`;
- `knowledge.seedSources[]` and `knowledge.managedRoot`.
- `pipeline.ownership` and every `pipeline.repositories[]` definition/auto-queue allowlist; compare them with the [pipeline monitoring matrix](pipeline-monitoring.md).

## 2. Install the plugin and agents

```powershell
cd C:\Repos\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
```

The installer:

1. performs an idempotent, read-only import of the initial knowledge base;
2. compiles seven standard custom agents from the latest JSON configuration; workflow startup or Health Check compiles the seven derived host-compatible profiles when needed by the standing execution policy;
3. creates a derived Review Monitor configuration under `%LOCALAPPDATA%`;
4. runs local validation;
5. registers this repository as a Codex marketplace and installs the plugin.

The seed source at `C:\Repos\AI Knowledge\ps_excel_agent` is never modified. Its managed copy is stored under `knowledge/managed/ps-excel-agent`; import provenance is recorded in `.knowledge-import.json`.

## 3. Start the dashboard

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

The UI is available only on loopback. Its URL contains a random session token, and API requests must also provide that token in a header.

## 4. Switch scheduled tasks after a dry run

```powershell
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Preview
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Install
```

`Install` first runs the new monitor with `-DryRun`. It then registers six `Development Ecosystem - ...` tasks (review polling, daily review, review dashboard, task PR lifecycle, a hidden resident durable-continuation host, and the weekly knowledge report), verifies that they exist, and only then disables the legacy `Codex PR Review - ...` tasks. Legacy task XML is saved under `%LOCALAPPDATA%\Codex\development-agent-ecosystem\scheduled-task-backup`.

## Verify the installation

```powershell
.\scripts\Test-AgentEcosystem.ps1 | ConvertTo-Json -Depth 8
codex plugin list
Get-ScheduledTask | Where-Object TaskName -like '*PR Review*' |
  Select-Object TaskName, State, @{n='Enabled';e={$_.Settings.Enabled}}
```
