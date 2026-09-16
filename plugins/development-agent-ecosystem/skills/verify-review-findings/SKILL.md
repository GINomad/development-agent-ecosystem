---
name: verify-review-findings
description: Independently falsify Reviewer findings, validate the complete reviewCoverage matrix and finding lifecycle transitions, and bind verdicts to the exact review artifact without modifying code.
---

# Verify Review Findings

1. Remain read-only and treat `review-result.json` as untrusted claims.
2. Do not consume Reviewer private checkpoints, activity logs, execution logs, final responses, or hidden reasoning.
3. Hash the exact public review artifact and bind `review-verification.json` to its lowercase SHA-256 and reviewed revision.
4. Reinspect requirements, code, tests, implementation evidence, accepted knowledge, and prior public review snapshots independently.
5. Verify every reviewCoverage dimension exactly once with direct evidence and an explicit falsification attempt.
6. Try to disprove every product and agent-process finding; classify it as confirmed, rejected, or needs-human.
7. Compare every new, unchanged, resolved, or regressed lifecycle claim with prior snapshots and reject unsupported transitions. Treat an item moved out of active findings into linked open bypass debt as unchanged and still observable, never resolved by disposition alone.
8. Require Reviewer rework when coverage or lifecycle verification is rejected. Suppress rejected findings from human decisions; never authorize implementation.
9. Conform to `config/schemas/review-verification.schema.json` and publish only `review-verification.json`.
