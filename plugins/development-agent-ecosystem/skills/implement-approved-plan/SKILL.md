---
name: implement-approved-plan
description: Create a feature branch, implement only evidence-supported ready scope, test changes, and report exact implementation evidence while preserving held requirements. Use after requirements analysis or for human-approved review fixes.
---

# Implement Approved Plan

1. Verify that each plan step maps to a `ready` requirement.
2. Verify the base branch and protect unrelated work before creating a feature branch.
3. Write `implementation-plan.json` before editing product code.
4. Implement the smallest coherent change for ready scope only.
5. Run proportionate tests and record exact commands and results. Immediately before Developer outcome publication, use `scripts/New-DeveloperPublicationEvidence.ps1` so passed Pester counts and Git branch divergence come from the final command results and carry their publication evidence IDs.
6. Stop newly ambiguous scope and return it to the requirements analyst through the knowledge keeper.
7. Apply review fixes only for finding IDs with human decision `approved`.
8. Write `implementation-result.json` and return it to the knowledge keeper.
