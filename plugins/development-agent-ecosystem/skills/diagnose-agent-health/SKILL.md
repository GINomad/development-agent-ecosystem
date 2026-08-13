---
name: diagnose-agent-health
description: Diagnose and maintain the development-agent ecosystem, including failures, stalled workflows, dashboard/API contracts, configuration, prompts, skills, tests, documentation, and control-plane change requests. Use for ecosystem defects or explicit ecosystem source changes; exclude product implementation.
---

# Diagnose agent health

1. For a failure, read the bounded diagnostic context and relevant task artifacts. For an explicit ecosystem change, read the routed request and only the affected ecosystem files.
2. Reproduce a defect with a read-only or prepare-only check, or translate a feature request into observable acceptance checks. Record the exact failure signature when one exists and identify the affected agent or control-plane component.
3. Classify the root cause or requested behavior before proposing a repair. Separate ecosystem scope from credentials, unavailable services, user-input gates, product code, and external writes.
4. Prefer `scripts/Invoke-EcosystemHealthCheck.ps1` for deterministic validation. Route `-Repair` through Knowledge Keeper only for the configured `safe-deterministic-only` actions. For a failed agent, require a structured artifact from `scripts/Write-AgentFailure.ps1`; automatic source recovery runs through `scripts/Start-AgentHealthRecovery.ps1` only in the ecosystem workspace and only once per failure signature.
5. Own source-controlled ecosystem changes through one bounded `ecosystem_recovery` plan. The recovery coordinator may edit only the ecosystem repository. Never edit product code, loosen permissions, reveal credentials, delete history, or perform external writes. Route product source changes to Developer.
6. Verify the exact requested behavior or failed check and then run `scripts/Test-AgentEcosystem.ps1`. Stop after one unsuccessful repair or repeated failure signature and return the blocker.
7. Report the request or diagnosis, evidence, repair, verification, and remaining risk. Publish verified durable learning to Knowledge Keeper only at the normal successful outcome or final task boundary.
