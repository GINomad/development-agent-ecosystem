# Stability boundaries for local agent execution

Status: accepted for the 2026-10-31 stabilization scope (STAB-001 through STAB-009).

## Context and evidence

The audit of revision `754fc6f` found concurrent global profile replacement, a semantic-validator failure that the existing 153-check suite did not exercise, coordinator lock timeouts, and a task marked running after its controller and lease disappeared. These are local control-plane failures. An expired or exhausted provider account is an external availability condition and does not authorize credential changes or source recovery.

## Decisions

1. Generate profiles in a task/run-specific launch bundle and register explicit Codex CLI `agents.<name>.config_file` overrides. Record the effective configuration hash, profile hashes and a fingerprint of the exact current source files, including an explicit dirty-worktree indicator. Reusing a run requires the same source/configuration and expected profile contents. Setup may still install global definitions; executing a task does not overwrite them.
2. Keep the coordinator lock limited to authoritative admission/lease/queue state. Perform task and manifest updates with exact identity checks under their own locks. Persist queue registrations for normal queue transitions. Direct manual editing of task state is not a supported queue-admission mechanism.
3. Diagnose missing leases read-only by default. Mutating recovery names an exact task and checks liveness and ownership; a prior attempt cannot alter a replacement run. File existence alone is not evidence that an OS lock is held.
4. Classify structured provider failures and explicit failure assertions. Transport retries have a separate finite budget, reset by actual provider progress; a long-running product command is not a transport timeout. Provider authentication/usage/transport failures preserve checkpoints as interrupted external availability, without source recovery.
5. Publish bounded scheduled-operation results and heartbeat even on a clean cycle. Deduplicate by full task/run/attempt identity. Report only measured lock percentiles and explicitly correlated repair/resume outcomes; missing historical identity is excluded, never imputed.

The profile override uses the supported [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference); the implementation remains a local PowerShell runner rather than a new provider or credential store.

## Alternatives and consequences

A global synchronization lock does not solve profile replacement: one run can read another run's later profiles after synchronization releases the lock. Per-run files provide isolation without another service or database. Reusing one global profile directory is retained only for explicit setup/legacy compatibility.

Holding a global lock across Git, filesystem scanning or waiting for task locks serializes unrelated tasks and can deadlock. Per-task work may wait for its own operations while the coordinator remains available to other tasks. Atomic writes protect file integrity; ownership checks and synchronization are also required to prevent stale writers.

There is no new autonomous retry of exhausted credentials, permission expansion or weakening of review/delivery gates. Source/profile fingerprint checks can require a new run after an ecosystem update; that is preferable to silently changing instructions halfway through a run.

## Validation, migration and rollback

Behavioral regressions execute real child processes and explicit contention barriers, cover positive and negative publication contracts, demonstrate cross-configuration isolation and reject tampered profile manifests. The main suite includes all four stability test groups. Windows PowerShell scheduled paths are exercised separately from the pwsh aggregate suite.

Legacy execution context without a bundle remains readable. Existing task artifacts and review hashes are preserved. Rollback is a normal source revision change followed by a new run; never rewrite historical outcomes or delete lock/history files. Do not delete an active run's bundle. Revisit bundle retention when disk measurements justify a bounded cleanup policy, and revisit the filesystem coordinator only if measured contention remains after these changes.
