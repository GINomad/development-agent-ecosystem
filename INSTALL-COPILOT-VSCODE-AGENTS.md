# Install the standalone ecosystem agents in GitHub Copilot for VS Code

This is the Copilot equivalent of the standalone Claude installer on branch `claude` (reference commit `62ed7cd`). The `copilot` branch starts from `main`. It contains eight native `.agent.md` profiles and five portable skills, including a standalone review-verification skill.

The installer uses file operations only. It does not install the PowerShell host, dashboard, schedules, automatic recovery, automatic push, or build queueing. The existing Codex runtime remains a separate installation path.

## Start installation

Open this branch in VS Code, open GitHub Copilot Chat with an agent that can read and edit files, and send:

```text
Read INSTALL-COPILOT-VSCODE-AGENTS.md completely and carry out its installation contract using built-in file operations only. Prefer user scope. Preserve existing configuration. Keep the knowledge base outside every Git repository. Do not run terminal commands, PowerShell, or installer scripts.
```

After installation, start a new chat and check the Agent dropdown for the eight `development-*` agents. Select `development-workflow-orchestrator` for multi-stage work, or choose a specialist directly. If a profile is absent, use Chat customization diagnostics to inspect discovery errors. Do not treat file existence as proof of successful loading or delegation.

## Installation contract

### Source and destination

Treat the directory containing this document as `SOURCE_ROOT`. Read the source files before copying them. The complete manifest is:

- `.github/agents/development-workflow-orchestrator.agent.md`
- `.github/agents/development-requirements-analyst.agent.md`
- `.github/agents/development-implementer.agent.md`
- `.github/agents/development-reviewer.agent.md`
- `.github/agents/development-review-verifier.agent.md`
- `.github/agents/development-knowledge-keeper.agent.md`
- `.github/agents/development-pipeline-monitor.agent.md`
- `.github/agents/development-health-check.agent.md`
- `.github/skills/apply-engineering-principles/SKILL.md`
- `.github/skills/develop-dotnet/SKILL.md`
- `.github/skills/develop-javascript-typescript/SKILL.md`
- `.github/skills/develop-react/SKILL.md`
- `.github/skills/verify-review-findings/SKILL.md`
- `.github/copilot-instructions.md` (managed routing block)

Prefer user scope on the host running the selected Copilot session:

- agents: `~/.copilot/agents/`
- skills: `~/.copilot/skills/`
- knowledge: `~/.copilot/development-agent-knowledge/`

Keep `.agent.md` extensions. The model field is intentionally omitted: agents use the model selected in Copilot, avoiding account-specific model IDs. Do not translate Codex model tiers or Claude `effort`, `maxTurns`, `disallowedTools`, or `skills` headers into unsupported VS Code properties.

User agents include their own contracts; do not assume that `~/.copilot/copilot-instructions.md` is loaded as global routing. User-scope installation works by selecting the orchestrator or specialist from the Agent dropdown. For repository-wide routing, merge the managed block into `<TARGET_REPOSITORY>/.github/copilot-instructions.md` only when the user chooses that target repository.

If user-scope agent or skill writes are blocked, use `<TARGET_REPOSITORY>/.github/agents/` and `.github/skills/`. Ask for the product repository when it is unknown; the ecosystem checkout is the source, not an implicit installation destination for another product. Record the selected scope. In remote or container sessions, resolve paths on the selected agent host, not the desktop filesystem.

The knowledge root has no repository fallback. Before installing, verify it is outside all Git repositories by inspecting the resolved destination and all ancestors for `.git` files or directories, including the home directory and ancestors above it. Inspect resolved symlink/junction targets as well. If this cannot be verified or the external directory cannot be created, stop before publishing a completed installation and report the blocked destination. Do not write knowledge into the product repository.

### Preserve configuration

Read every existing destination before writing. Identical files remain unchanged. If a destination differs, show the specific conflict and request a decision for that file; do not overwrite unrelated agents, skills, or settings. Do not install runtime skills from `plugins/`: the manifest above is the portable set. Its verification skill deliberately differs from the full-runtime skill.

For routing, preserve all text outside these markers and replace at most one existing managed block:

```text
<!-- development-agent-standalone:start -->
<!-- development-agent-standalone:end -->
```

If markers are duplicated, unmatched, or reversed, report the conflict before editing. With no block, append one. Re-running the installation must not duplicate blocks, catalog entries, or knowledge files. Do not create secret-bearing backups or change permission/auto-approval settings.

### External project knowledge

Create only missing files in this layout, preserving existing content:

```text
~/.copilot/development-agent-knowledge/
  README.md
  catalog.md
  global/
    engineering-practices.md
  projects/
    <project-key>/
      README.md
      verified-knowledge.md
      decisions.md
      task-history.md
```

Resolve the product repository identity from permitted repository context. Prefer a credential-free canonical remote: host, owner, repository. Remove user info, query, fragment, port, and trailing `.git`. Never display or persist the original remote if it contains credentials. Lowercase the identity and replace non-alphanumeric runs with hyphens. Check the catalog before using the key; preserve its established mapping. Resolve collisions with a stable non-secret suffix, without merging distinct projects. Multiple repositories belong to one project only when the user explicitly declares that relationship.

Without a visible remote, use the normalized absolute local path as `identitySource: local-path`, with a folder-based key plus a stable disambiguator recorded in the catalog. If the target product repository is unknown, ask for it before creating a project entry. Never initialize the ecosystem source as the product by accident.

The catalog stores the project key, sanitized remote or normalized path, identity source, and verification date. Project README stores scope and identity. `verified-knowledge.md` contains current evidence-backed facts; `decisions.md` accepted decisions with source/date; `task-history.md` concise verified completed outcomes with revision or file evidence. Initialize new files with headings and their purpose, without inventing project facts. Reusable engineering practices belong in `global/`; product-specific facts stay in their project directory.

Do not persist transcripts, hidden reasoning, raw logs, source-code copies, secrets, personal data, speculative plans, failed attempts, or unverified findings. After installation, only Knowledge Keeper updates generated knowledge. The installer is authorized to initialize the empty structure and identity mapping.

### Verify with file tools

1. Compare each installed profile and skill against the manifest source. Confirm eight unique agent names, five skill names matching their directories, and exactly one YAML header per file.
2. Check that analyst, reviewer, verifier, and pipeline monitor have no edit or execution tools. Only the orchestrator has `agent` access and it lists the seven specialists. Other roles use `agents: []`.
3. Confirm all handoff targets exist and every handoff uses `send: false`. Confirm there are no Claude/Codex model IDs or unsupported frontmatter properties.
4. If repository routing was requested, verify exactly one complete managed block and preservation of surrounding text.
5. Verify the resolved external knowledge root, one catalog entry per project, and the four project files. Confirm no generated knowledge was placed in a product repository.
6. Report chosen scope and absolute destinations, installed/unchanged/conflicting files, routing status, project identity, external root, and blocked operations. Report discovery and live agent behavior as unverified until the user checks the Agent dropdown in a new chat.

## Capability limits

Read-only reviewers cannot execute tests. The implementer may run approved non-PowerShell validation; report unsupported commands as unverified. Pipeline Monitor can read available provider pages, but private CI often needs an authenticated provider integration that this pack does not provision. It never queues a run. Knowledge Keeper needs approved file access to the external root; a tool allowlist is not a path sandbox.

The orchestrator invokes named specialists only if the active VS Code harness supports that operation. Otherwise it returns explicit handoff prompts. Handoff buttons assist manual transitions; they do not implement the full ecosystem's deterministic gates or scheduled execution. Separate review and verifier invocations improve independence but do not guarantee runtime artifact isolation.

## References

Format and discovery paths checked on 2026-09-24:

- [VS Code custom agents](https://code.visualstudio.com/docs/agent-customization/custom-agents)
- [VS Code agent skills](https://code.visualstudio.com/docs/agent-customization/agent-skills)
- [GitHub custom agent configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration)
