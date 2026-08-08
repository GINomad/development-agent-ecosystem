---
name: ps-excel-change-workflow
description: Inspect, plan, implement, diagnose, and verify changes in the ps-excel-agent repository. Use for general feature work, bug fixes, repository questions, refactoring, or test work that is not fully covered by a narrower authentication, calculation/scenario, delivery, or review skill.
---

# PS Excel change workflow

Follow this sequence:

1. Classify the request: explain, diagnose, review, implement, or perform an external operation.
2. Inspect the worktree and preserve unrelated changes.
3. Search the active call path before opening many files.
4. Read [references/project-map.md](references/project-map.md) when locating components or boundaries.
5. Read [references/verification.md](references/verification.md) before choosing checks.
6. Load a narrower domain skill if the trace reaches authentication, calculation/scenarios, Office cancellation, Docker/runtime configuration, or PR review.
7. Make minimal, coherent edits only when authorized.
8. Inspect the diff and run focused verification.
9. Report outcome, evidence, checks, and remaining risk.

Treat all reference facts as dated knowledge. Re-read the current project, package, manifest, and pipeline files when versions or behavior matter.

Do not modify binary workbook fixtures unless explicitly requested. Do not discard unrelated files such as a root `package-lock.json` or temporary Excel lock files.
