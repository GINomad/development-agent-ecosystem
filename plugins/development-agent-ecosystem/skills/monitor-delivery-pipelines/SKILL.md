---
name: monitor-delivery-pipelines
description: Integrate exact-branch and exact-commit Azure pipeline monitoring into the task workflow, publish bounded successful outcomes for shared knowledge, and route remediation or completed-PR control signals through the orchestrator. Use only after an authorized push or an explicit pipeline monitoring request.
---

# Monitor Delivery Pipelines

1. After a clean local review and passing independent verification bound to its exact SHA, call `scripts/Invoke-ReviewedBranchDelivery.ps1`; otherwise require proof of a successful authorized push, repository ID, exact branch, full pushed SHA, and pre-push UTC timestamp.
2. The delivery script performs the guarded non-force branch push and calls `scripts/Invoke-PostPushPipeline.ps1 -PushWasSuccessful`; the latter uses the vendored `azure-pipeline-monitor`.
3. Apply only the repository-specific build allowlist from `config/agents.json`; never infer a definition and never auto-queue a deployment.
4. Let the native watcher wait for every exact-SHA run to reach a terminal state without model polling. If its command yields a running cell or session, retain the handle and use the provided wait/resume mechanism until the same watcher command completes; do not start another refresh or watcher while that handle is live. Treat an `inProgress` result or execution yield as ongoing work, not a failure; only terminal watcher completion or a real nonzero exit can drive result/failure handling.
5. Treat failed, partially succeeded, canceled, and timed-out runs as non-success.
6. Bound failed task excerpts by the configured line and byte limits, classify them deterministically, and write `pipeline-result.json`.
7. Route only `code` and `test` failures to Developer, once per failure signature and within the configured three-cycle ceiling.
8. After producing a valid terminal artifact, publish one bounded successful Pipeline Monitor outcome so Knowledge Keeper can ingest verified delivery evidence; never send progress dumps or failed private context.
9. For any non-success that requires a human owner, expose why automation stopped, concrete resolution options, the recommended option, and why it is preferred; do not return a bare blocker.
10. After build success, synchronize the task PR once. Keep active or absent PRs waiting, open a human-input gate for abandoned PRs, and report completed-PR closure evidence to Orchestrator. Only Orchestrator may route the final publication command to Knowledge Keeper.
