---
name: PS Excel knowledge maintenance
description: Keep the canonical project knowledge base synchronized with verified engineering work.
applyTo: "**"
---

After completing and verifying material work, evaluate whether it produced durable knowledge for future tasks.

- Canonical knowledge root: `C:\Repos\AI Knowledge\ps_excel_agent`.
- Persist final technical decisions, reusable rules, known failure modes, rejected approaches worth avoiding, architecture changes, and verified workflows.
- Do not persist guesses, unfinished experiments, raw transient logs, secrets, tokens, credentials, or routine changes already obvious from current code.
- Update the existing document that owns the topic. Use `coding-style.md` for explicit style preferences, `coding-knowledge.md` for reusable technical decisions, `docker-update.md` for delivery/runtime history, and `conversation history` for task-specific chronology.
- Include evidence, affected files, verification, date, limitations, and superseded behavior.
- Reconcile the matching skill reference when the new knowledge changes future agent behavior.
- If the canonical path is unavailable or write access is denied, report the exact pending update instead of claiming it was saved.
