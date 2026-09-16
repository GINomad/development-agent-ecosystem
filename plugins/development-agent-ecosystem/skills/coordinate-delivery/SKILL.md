---
name: coordinate-delivery
description: Route and coordinate requirements, knowledge, implementation, candidate review, independent verification, human decisions, and pipeline monitoring with targeted restarts, explicit artifact gates, and per-task history.
---

# Coordinate Delivery

1. Use Workflow Orchestrator as the task/comment control plane. Use Knowledge Keeper only as an on-demand verified knowledge service and final curator.
2. Classify the requested outcome and select the narrowest configured execution mode before choosing agents. Route later comments to the smallest sufficient responsible agent set inside that mode.
3. Treat research-only and no-code instructions as hard boundaries: run Requirements Analyst only, publish its outcome, and do not continue into Developer, Reviewer, Review Verifier, or Pipeline Monitor.
4. Persist routing and its execution mode without changing running, completed, waiting, or failed state. When new evidence changes completed, waiting, interrupted, or failed work, request a targeted restart and let the trusted host start that agent after the Orchestrator succeeds.
5. When a targeted comment is outside the receiving role's configured responsibilities, use `Request-OrchestratorCommentRouting.ps1` to link and forward it once. Trusted host continuation must prioritize Orchestrator and then the earliest eligible routed owner without a manual restart.
6. Allow implementation only for ready scope; retain partial holds for unresolved scope.
7. Require implementation plan and result artifacts before Reviewer publishes candidates, the complete reviewCoverage matrix, and stable finding lifecycle records.
8. Run Review Verifier in a separate read-only invocation. Require independent coverage, finding, and lifecycle verdicts bound to the exact review SHA; return rejected coverage or lifecycle claims to Reviewer.
9. Expose only confirmed or needs-human findings to the human decision/rework gate. Verifier-rejected findings remain auditable but cannot block delivery or authorize changes.
10. After a passing verification and an authorized push, invoke exact-commit pipeline monitoring.
11. Batch pending comments at one checkpoint. Never poll roles, repeatedly call wait, or use collaboration wait when no child agent is running.
12. After publishing the current role outcome, return control immediately to the trusted host continuation. Do not idle-wait for the next role or start it inside the same targeted invocation.
13. Keep working context private for waiting or failed roles. Publish only validated successful outcomes to shared history.
14. Finish and write the task summary only when required scope is done; a task with held questions remains waiting, not completed.
