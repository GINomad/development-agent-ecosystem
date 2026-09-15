---
name: review-ps-excel-change
description: Review a PS Excel Agent diff for actionable defects.
agent: PS Excel Reviewer
argument-hint: Provide the PR, branch, commit, or diff scope and base.
---

Review the specified change set. Establish the exact base and head, then follow the repository `code-review` skill.

Return findings ordered by severity. Each finding must include evidence and a concrete failure scenario. Keep summaries brief; if no actionable defect is found, state that clearly and list only residual verification gaps.
