# PS Excel Copilot Agent Pack

This package installs repository-scoped GitHub Copilot customizations for `ps-excel-agent`:

- `AGENTS.md` for cross-agent working behavior;
- `.github/copilot-instructions.md` for always-on repository facts;
- path-specific `.instructions.md` files;
- two custom agents;
- reusable prompt files;
- task-specific agent skills with an embedded, portable knowledge base.

The source knowledge was distilled from `C:\Repos\AI Knowledge\ps_excel_agent` on 2026-08-05 and checked against the current repository. Historical notes are guidance, not a substitute for inspecting the active branch.

## Install into a repository

From PowerShell:

```powershell
& .\copilot-agent-pack\install.ps1 -TargetRoot C:\Repos\ps-excel-agent
```

The installer refuses to overwrite existing files. Review conflicts first; use `-Force` only after deciding that the package version should replace them.

```powershell
& .\copilot-agent-pack\install.ps1 -TargetRoot C:\Repos\ps-excel-agent -Force
```

Commit the installed `AGENTS.md` and `.github` files so the same behavior is available in VS Code, GitHub Copilot code review, Copilot cloud agent, and Copilot CLI where each customization type is supported.

## Load and use in VS Code

1. Open the target repository as the VS Code workspace.
2. Run `Chat: Open Customizations` from the Command Palette.
3. Confirm that the Instructions, Agents, Prompts, and Skills tabs show the installed files.
4. Select `PS Excel Engineer` in the agent dropdown for normal work or `PS Excel Reviewer` for a findings-only review.
5. Run prompts by typing `/implement-ps-excel-change`, `/diagnose-ps-excel`, `/review-ps-excel-change`, or `/refresh-ps-excel-knowledge` in Copilot Chat.
6. Skills are selected automatically from their descriptions and can also appear as slash commands.

If customizations do not appear, right-click the Chat view and open Diagnostics. Ensure the workspace root is the repository root, not only a nested UI or backend folder.

## Personal installation

For reuse across repositories, copy only generic pieces through the VS Code `Chat: Open Customizations` editor:

- agents to the user-level agents location (`~/.copilot/agents` when Agent Host is enabled);
- skills to `~/.copilot/skills`;
- instructions to `~/.copilot/instructions`.

Do not install the PS Excel project rules globally unless every repository you work on uses the same architecture and conventions. Workspace installation is the recommended mode.

## Notes

- Prompt files are intended for local VS Code chat. Agent Host sessions may ignore prompt files; use the equivalent skills/custom agent in that environment.
- The pack does not include secrets, tokens, private URLs, or machine-specific report paths.
- The installer only copies files. It does not change VS Code settings, run builds, or contact GitHub/Azure DevOps.
