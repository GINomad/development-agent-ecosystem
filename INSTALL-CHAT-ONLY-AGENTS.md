# Install the agents without the dashboard

The standalone profile installs eight development agents and five portable engineering skills without the dashboard, scheduler, task ledger, or automatic continuation. It is suitable when the agents will be selected directly in a provider chat.

## File-based installation

Preview the exact destinations first, then repeat without `-Preview`:

```powershell
.\scripts\Install-ChatOnlyAgents.ps1 -Provider codex -Preview
.\scripts\Install-ChatOnlyAgents.ps1 -Provider copilot -Preview
.\scripts\Install-ChatOnlyAgents.ps1 -Provider claude -Preview
```

Use `-DestinationRoot` for project scope. Without it, the script targets the current user's `.codex`, `.copilot`, or `.claude` directory. Existing identical files are preserved; a differing file is reported as a conflict and is never overwritten.

Authentication remains provider-owned. Codex uses the application account session. For the other CLIs run:

```powershell
.\scripts\Start-AgentProviderLogin.ps1 -Provider copilot
.\scripts\Start-AgentProviderLogin.ps1 -Provider claude
```

The ecosystem never reads or stores provider tokens.

## Installation by pasting one request into chat

- GitHub Copilot: paste the request in `INSTALL-COPILOT-VSCODE-AGENTS.md` into Copilot Chat.
- Claude: paste the request in `INSTALL-CLAUDE-VSCODE-AGENTS.md` into Claude Code.
- Codex: ask Codex to read this file and run `Install-ChatOnlyAgents.ps1 -Provider codex -Preview`, report conflicts, and continue without `-Preview` only after you approve the destinations.

Standalone agents do not claim dashboard/runtime capabilities. Their knowledge directories remain outside product repositories.
