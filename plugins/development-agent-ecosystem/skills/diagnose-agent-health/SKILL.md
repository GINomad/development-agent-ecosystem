---
name: diagnose-agent-health
description: Diagnose development-agent ecosystem failures, stalled or orphaned workflows, dashboard and API contract errors, generated-agent drift, and invalid runtime state. Use when an agent exits unexpectedly, a task is failed or stuck, a dashboard action errors, required artifacts are missing, or Knowledge Keeper needs an evidence-backed safe repair route.
---

# Diagnose agent health

1. Read the task's `task.json`, `task-ledger.jsonl`, `health-check-result.json`, `workflow-codex.jsonl`, and produced artifacts. Read the canonical JSON configuration and relevant scripts only when the failure points there.
2. Reproduce with a read-only or prepare-only check. Record the exact failure signature, timestamps, process IDs, exit code, and affected agent.
3. Classify the root cause before proposing a repair. Separate ecosystem defects from credentials, unavailable services, user-input gates, and product-code failures.
4. Prefer `scripts/Invoke-EcosystemHealthCheck.ps1` for deterministic validation. Route `-Repair` through Knowledge Keeper only for the configured `safe-deterministic-only` actions. For a failed agent, require a structured artifact from `scripts/Write-AgentFailure.ps1`; automatic source recovery runs through `scripts/Start-AgentHealthRecovery.ps1` only in the ecosystem workspace and only once per failure signature.
5. Never edit product code, loosen permissions, reveal credentials, delete history, or perform external writes. Route source changes to Developer with evidence and verification steps.
6. Verify the exact failed check and then run `scripts/Test-AgentEcosystem.ps1`. Stop after one unsuccessful repair or repeated failure signature and return the blocker.
7. Report diagnosis, evidence, repair, verification, and remaining risk to Knowledge Keeper. Do not claim recovery until the checks pass.
