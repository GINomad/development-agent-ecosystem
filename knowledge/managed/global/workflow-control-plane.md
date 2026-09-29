# Workflow Control-Plane Knowledge

## Manual closure final publication

Verified on 2026-09-24 for all workflow execution modes: an explicit manual closure in `knowledge-update-pending` state authorizes Knowledge Keeper as the sole terminal publication target, even when the prior execution-mode sequence did not include Knowledge Keeper. The continuation must not restart excluded product delivery roles.

Applicability: use this rule only for persisted manual closures. It does not alter normal delivery sequencing, approval gates, or product repository scope.

Evidence: task `task-ecosystem-local-poc-finalization-20260915`, `health-check-result.json` revision `888fc5fd0ca33c877746b3f963f0eea0b700827c2acf41412199f1785aac2258`; `scripts/Test-AgentEcosystem.ps1` passed, including the manual-closure dispatch regression.
