# Workflow Control-Plane Knowledge

## Manual closure final publication

Verified on 2026-09-24 for all workflow execution modes: an explicit manual closure in `knowledge-update-pending` state authorizes Knowledge Keeper as the sole terminal publication target, even when the prior execution-mode sequence did not include Knowledge Keeper. The continuation must not restart excluded product delivery roles.

Applicability: use this rule only for persisted manual closures. It does not alter normal delivery sequencing, approval gates, or product repository scope.

Evidence: verified ecosystem regression checks. Private task provenance is retained locally in knowledge/local/workflow-control-plane-provenance.md.

## Exact-bound terminal-result reconciliation

Verified on 2026-10-06: a late host or process failure must be rejected or marked stale when its execution-run or agent identity conflicts with a newer exact-bound successful terminal agent result. Task-status reconciliation must retain that authoritative success and must not transfer the failure to an unrelated agent. Genuine repeated failures with matching identity remain subject to the configured retry and recovery limits.

Applicability: use this rule in workflow-host failure writers and task-status reconcilers that consume delayed process or host failure events. It protects terminal-result ordering; it does not suppress identity-matching real failures.

Evidence: verified ecosystem regression checks. Private task provenance is retained locally in knowledge/local/workflow-control-plane-provenance.md.
