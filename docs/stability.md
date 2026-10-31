# Stability operations

Scheduled PR review writes its latest bounded result to `stateRoot/health/scheduled-review-{poll,daily,manual}.json` before returning. A failed scheduled invocation records only a redacted, 480-character error summary and then fails the PowerShell process so Task Scheduler reports the true exit state.

`Write-RoleAttemptMetric.ps1` uses a bounded exclusive lock and treats an attempt as idempotent only for the tuple `(taskId, runId, attemptId)`. Lock contention is returned as deferred telemetry; it does not rewrite a completed role outcome. Optional execution-bundle provenance is persisted only when supplied by the launch path.

`Get-EcosystemStabilityReport.ps1` is an evidence report, not an SLO. It keeps expected external auth/usage, control-plane, product/hold/conflict, stale history, and records with missing run/attempt identifiers separate. Any denominator that cannot be evidenced is `null`.
