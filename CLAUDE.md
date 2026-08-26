# Claude Code repository instructions

This repository is the deterministic control plane for a development-agent ecosystem. Read `README.md`, `docs/claude-code.md`, `docs/architecture.md`, and `config/agents.json` before changing runtime behavior.

- PowerShell owns workflow state, transitions, locks, health recovery, validation, commits, pushes, and external-write gates. Do not replace it with Claude agent teams, background agents, or an implicit chat-only handoff.
- Agent definitions under `plugins/development-agent-ecosystem/agents/` are generated. Change canonical entries in `config/agents.json`, prompt sources, or skills, then run `scripts/Sync-AgentDefinitions.ps1 -Install`.
- Run `scripts/Test-AgentEcosystem.ps1` after ecosystem changes. Use `Start-DevelopmentWorkflow.ps1 -PrepareOnly` when validating prompt/routing construction without spending model tokens.
- Never request or persist plaintext passwords, PATs, API keys, refresh tokens, or cookies. Ask the developer to authenticate in their own terminal, then verify only status or account metadata.
- Do not infer approval for force push, base-branch push, deployment, work-item mutation, review-comment publication, or destructive workspace cleanup.
- For first-time developer setup, follow `SETUP_WITH_LLM.md` as an interactive interview. Do not skip its preview and validation gates.

Claude Code is an execution provider, not the orchestrator of record. A successful role must publish its persisted outcome and return to the trusted host so the host can select the next role.
