---
name: ps-excel-knowledge-base
description: Locate, use, and maintain the canonical ps-excel-agent engineering knowledge base, historical decisions, conversation summaries, Docker notes, architecture documents, and PR-review guidance. Use for project knowledge, prior decisions, history, known patterns, or files under C:\Repos\AI Knowledge\ps_excel_agent.
---

# PS Excel knowledge base

1. Read [references/catalog.md](references/catalog.md) to choose the smallest relevant source set.
2. Use the canonical local root `C:\Repos\AI Knowledge\ps_excel_agent` when it is accessible.
3. Read only documents relevant to the task. Search headings and keywords before loading long histories.
4. Treat dates, versions, branches, package APIs, and prototypes as historical until the active repository confirms them.
5. Prefer current source and tests when knowledge conflicts with code.
6. Distinguish final decisions from superseded experiments and parked concepts.
7. After completing and verifying material project work, decide whether it produced durable knowledge that future tasks need.
8. Persist confirmed durable knowledge in the canonical root. Do not persist guesses, transient command output, secrets, tokens, machine-only noise, or unverified prototypes.
9. Update the existing canonical document that owns the topic. Create a new document only when no existing file has a clear scope.
10. Record the decision, evidence, affected files, verification, date, and any explicit limitation or superseded approach.
11. Reconcile the matching bundled skill reference when the new fact changes agent behavior.

If the external root is unavailable, use the distilled references in the other `ps-excel-*` skills and disclose that the canonical source was not read.

## Maintenance routing

- Put explicit coding preferences in `coding-style.md`.
- Put reusable implementation rules, known failures, and final technical directions in `coding-knowledge.md`.
- Put Docker, runtime configuration, deployment, and pipeline history in `docker-update.md`.
- Put task-specific investigation and chronological context in the matching file under `conversation history`.
- Update `knowledge-discovery.md` only for durable repository architecture or tooling changes.
- Update this skill's catalog when adding, renaming, or retiring a canonical knowledge document.

Preserve useful superseded history when it prevents repeating a failed approach, but label it clearly as superseded and make the latest final direction unambiguous.
