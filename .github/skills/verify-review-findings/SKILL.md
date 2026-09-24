---
name: verify-review-findings
description: Independently verify a public code review against the exact source snapshot, including findings, coverage, and lifecycle claims. Use after standalone review; return evidence without editing code or authorizing fixes.
---

# Verify standalone review findings

1. Remain read-only. Receive the public review, requirements, repository, reviewed revision and any uncommitted diff identity. If the snapshot changed, require a refreshed review; do not carry verdicts to a different patch.
2. Treat reviewer claims as untrusted. Do not consume private checkpoints or hidden reasoning. Reinspect code, callers, tests, requirements, and accepted decisions independently.
3. Try to disprove each finding. Keep its stable ID, record the falsification attempt and direct evidence, then return exactly one verdict: `confirmed`, `rejected`, or `needs-human`. The last verdict requires a specific unresolved product or policy decision.
4. Check all ten coverage dimensions: requirements, correctness, security, regression, testing, maintainability, performance, concurrency, configuration/deployment, and documentation. Give an evidence-backed verdict on each coverage claim. Reject unsupported not-applicable claims; report blocked evidence explicitly.
5. Compare new, unchanged, resolved, and regressed claims with prior public reports. Missing evidence is not resolution. Accepted bypasses remain observable and unresolved.
6. Return the review identity, source snapshot, per-finding verdicts, coverage verdicts, lifecycle checks, and required reviewer rework. When a public report hash is available, carry it unchanged; otherwise quote its exact public identifier and date and disclose the weaker identity. Never invent a hash or claim deterministic runtime gating.
7. Rejected findings cannot justify implementation. Confirmed findings still require existing user authorization or a user decision. Return to the parent; do not edit reports, code, tests, branches, or provider state.

This standalone skill returns its result in the conversation. It requires no ecosystem schemas, task artifacts, shell commands, or publication scripts.
