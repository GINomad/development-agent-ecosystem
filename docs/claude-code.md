# Claude Code port and developer prerequisites

## Architecture

Claude Code is the model runtime. The existing PowerShell trusted host remains the orchestrator of record and owns task ledgers, role transitions, workspace leases, resumability, health recovery, commits, pushes, pipeline gates, and final validation. The runtime invokes one selected plugin agent per headless `claude -p` process; it does not use Claude agent teams as a second state machine.

Canonical agents are defined in `config/agents.json` and compiled into `plugins/development-agent-ecosystem/agents/*.md`. Skills remain under the plugin's `skills/` directory. `.claude-plugin/marketplace.json` publishes the local marketplace and the plugin manifest is `plugins/development-agent-ecosystem/.claude-plugin/plugin.json`.

## Additional setup required for Claude

Claude Code is not bundled with this repository. On Windows, install it using Anthropic's current native installer or WinGet, then authenticate:

```powershell
winget install Anthropic.ClaudeCode
claude --version
claude auth login
claude auth status
claude doctor
```

Native Windows uses PowerShell and can optionally use Git for Windows. WSL 2 provides Linux sandboxing, but all configured product workspace paths must then be WSL paths and the scheduled host must also run inside WSL. Do not mix Windows and WSL paths in one configuration.

Validate and install the local plugin:

```powershell
cd C:\Repos\development-agent-ecosystem
claude plugin validate .
claude plugin marketplace add . --scope user
claude plugin install development-agent-ecosystem@planning-space-development --scope user
.\scripts\Sync-AgentDefinitions.ps1 -Install
.\scripts\Test-AgentEcosystem.ps1
```

`Install-AgentEcosystem.ps1` performs the validation, marketplace registration, and plugin installation automatically after Claude is available and authenticated.

## Permissions

The committed Claude runtime uses `auto` permission mode. It supports unattended classification while retaining Claude Code's safety decisions. Project settings explicitly deny force push, hard reset, and clean commands. Delivery scripts add independent branch, remote, SHA, and allowlist validation.

`bypassPermissions` is not Windows elevation: it disables permission prompts. The canonical schema rejects it as a committed runtime default. If an administrator accepts that risk for an isolated disposable machine, use a separately reviewed one-off Claude invocation and preserve every deterministic ecosystem gate.

## Headless runtime contract

Workflow runs use `claude -p` with stream-JSON output, a selected plugin agent, model and effort selected by `Resolve-AgentModelRoute.ps1`, bounded turns, no session persistence, and the local plugin directory. The execution guard captures the stream and the final result exporter writes the compatible final-response artifact. Health recovery uses Claude structured output with the canonical JSON schema.

Claude must publish the role's persisted outcome before it exits. A normal textual answer without the required task artifacts is a failed role run. Successful outcomes always return to the PowerShell host; only that host dispatches the next role.

## First-time configuration

For a new developer, open the repository with any capable LLM and instruct it to follow `SETUP_WITH_LLM.md`. The setup interview covers repository URLs and paths, provider login status, task sources, pipelines, reviewer identity, knowledge roots, schedules, and permissions. Secret values must be entered by the developer directly into provider login tools, never into the chat or repository.

Current Anthropic documentation:

- https://code.claude.com/docs/en/installation
- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/sub-agents
- https://code.claude.com/docs/en/plugin-marketplaces
- https://code.claude.com/docs/en/permissions
