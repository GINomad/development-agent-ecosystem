# Install for VS Code and Visual Studio

Canonical source:

```text
C:\Repos\AI Knowledge\ps_excel_agent\exports\copilot-agent-pack
```

Canonical knowledge base:

```text
C:\Repos\AI Knowledge\ps_excel_agent
```

## Recommended installation

Install repository customizations plus personal skills and agents:

```powershell
& 'C:\Repos\AI Knowledge\ps_excel_agent\exports\copilot-agent-pack\install-both-ides.ps1' `
  -Scope All `
  -TargetRoot 'C:\Repos\ps-excel-agent'
```

The repository copy supplies always-on instructions, path-specific instructions, prompts, agents, and skills to both IDEs. The personal copy makes the agents and skills discoverable outside a repository installation.

The installer refuses to overwrite existing files unless `-Force` is supplied.

## VS Code: use the canonical path directly

Merge the properties from `vscode-settings.snippet.json` into VS Code user or workspace `settings.json`. They point VS Code directly at the canonical skills, agents, instructions, and prompts and grant read-only agent access to the knowledge directory.

Run `Chat: Open Customizations` and confirm that the files are listed. Select `PS Excel Engineer` in the agent picker.

If the VS Code build or organizational policy rejects an absolute customization path, use `-Scope Personal`. The default personal locations are under `%USERPROFILE%\.copilot`.

## Visual Studio

Requirements:

- custom agents: Visual Studio 2026 18.4 or later;
- agent skills: Visual Studio 2026 18.5 or later;
- Copilot subscription and agent mode.

Install the personal skills and agents:

```powershell
& 'C:\Repos\AI Knowledge\ps_excel_agent\exports\copilot-agent-pack\install-both-ides.ps1' `
  -Scope Personal
```

This copies:

```text
skills  -> %USERPROFILE%\.copilot\skills
agents  -> %USERPROFILE%\.copilot\agents      (VS Code)
agents  -> %USERPROFILE%\.github\agents       (Visual Studio)
```

In Visual Studio, enable custom instructions under `Tools > Options > GitHub > Copilot`. Repository instructions and prompts are discovered from `.github` after repository installation. Select `PS Excel Engineer` from the agent picker. In Visual Studio 2026 Insiders 18.6+, use the Skills panel for discovery diagnostics.

Visual Studio does not document an arbitrary external folder setting for skills. Use its supported personal location or install the repository template. The custom-agent location can be changed under `Tools > Options > GitHub > Copilot` if you prefer to point it at the canonical `repository\.github\agents` directory.

## Prompt to force knowledge loading

```text
Use the ps-excel-agent skills installed from
C:\Repos\AI Knowledge\ps_excel_agent\exports\copilot-agent-pack\repository\.github\skills.

For project history and domain decisions, use the knowledge root
C:\Repos\AI Knowledge\ps_excel_agent.

Start with the ps-excel-knowledge-base skill, read only the documents relevant
to this task, and verify every historical statement against the current branch
before editing. Preserve unrelated worktree changes and run focused verification.
```

## Updating

Edit the canonical package under `C:\Repos\AI Knowledge\ps_excel_agent\exports\copilot-agent-pack`, validate it, and rerun the installer with `-Force` after reviewing conflicts.
