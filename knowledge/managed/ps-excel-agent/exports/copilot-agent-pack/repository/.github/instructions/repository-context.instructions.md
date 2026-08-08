---
name: PS Excel repository context
description: Always-on architecture and working constraints when customizations are loaded from an external directory.
applyTo: "**"
---

This repository implements a Planning Space integration for Microsoft Excel with an ASP.NET Core backend, MSTest tests, and a React/TypeScript/Office.js add-in.

- Inspect the current branch and relevant code before relying on historical knowledge.
- Preserve unrelated worktree changes and binary workbook fixtures.
- Use braces for every conditional branch.
- Keep C# classes in separate files, use explicit access modifiers, and avoid controller-level `try`/`catch` wrappers without approval.
- Reuse shared UI API, authentication, token-update, and logging helpers.
- Treat authentication, calculation lifecycle, scenario mapping, runtime configuration, manifests, Docker, and pipelines as high-risk areas requiring the matching skill.
- Never place credentials or tokens in code, logs, prompts, or committed configuration.
- Inspect the diff and run focused verification after edits. Report skipped or blocked checks accurately.
