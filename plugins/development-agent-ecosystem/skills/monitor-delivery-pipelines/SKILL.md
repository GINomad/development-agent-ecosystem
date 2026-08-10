---
name: monitor-delivery-pipelines
description: Integrate exact-branch and exact-commit Azure pipeline monitoring into the task workflow and return terminal results and failure evidence to the knowledge keeper. Use only after an authorized push or an explicit pipeline monitoring request.
---

# Monitor Delivery Pipelines

1. After a clean local review, call `scripts/Invoke-ReviewedBranchDelivery.ps1`; otherwise require proof of a successful authorized push, repository ID, exact branch, full pushed SHA, and pre-push UTC timestamp.
2. The delivery script performs the guarded non-force branch push and calls `scripts/Invoke-PostPushPipeline.ps1 -PushWasSuccessful`; the latter uses the vendored `azure-pipeline-monitor`.
3. Apply only the repository-specific build allowlist from `config/agents.json`; never infer a definition and never auto-queue a deployment.
4. Let the native watcher wait for every exact-SHA run to reach a terminal state without model polling.
5. Treat failed, partially succeeded, canceled, and timed-out runs as non-success.
6. Bound failed task excerpts by the configured line and byte limits, classify them deterministically, and write `pipeline-result.json`.
7. Route only `code` and `test` failures to Developer, once per failure signature and within the configured three-cycle ceiling.
8. Return run links, results, classification, remediation state, and focused evidence to Knowledge Keeper.
9. On build success, call `scripts/Sync-TaskPullRequestStatus.ps1` once. Only a completed PR requests final task completion and the Knowledge Keeper update; active or absent PRs remain pending, and abandoned PRs require human input.
