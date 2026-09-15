---
name: code-review
description: Perform a read-only review of a pull request, branch, commit, staged change, working-tree diff, or selected files in ps-excel-agent. Use for Copilot code review and any request to review, audit, inspect, or find regressions in a change set.
---

# PS Excel code review

1. Establish the exact base, head, and scope. Do not review an unrelated or stale diff.
2. Inspect the worktree without changing it.
3. Read [references/review-checklist.md](references/review-checklist.md).
4. Load any matching domain skill and read surrounding call paths, not only changed lines.
5. Check tests and configuration that exercise the changed behavior.
6. Report only actionable defects introduced or exposed by the change.

Each finding must include:

- severity;
- file and line;
- concrete evidence;
- realistic failure scenario or violated contract;
- smallest safe remediation direction.

Order findings by severity. Do not publish comments, edit code, push, or queue builds during a review unless the user separately authorizes that action.

If there are no findings, say so and identify only residual verification gaps. Do not invent stylistic findings to fill the response.
