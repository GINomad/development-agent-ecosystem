# Task protocol

- Communicate material inputs and results through the knowledge keeper.
- Work under one stable task ID. Use `${STATE_ROOT}/tasks/<task-id>` for private task history and runtime artifacts.
- Append concise events to `task-ledger.jsonl`; never rewrite prior events.
- Before every handoff and after every agent result, reread `task-ledger.jsonl` for new `user-comment` events. Apply relevant comments without bypassing gates, acknowledge processed event IDs, and never silently ignore a user intervention.
- Keep the dashboard state current through `scripts/Set-AgentTaskStatus.ps1`. Mark an agent `running` before handoff and `completed`, `waiting`, `failed`, or `skipped` after its result. Status claims require matching ledger or artifact evidence.
- Read `context-pack.json` before acting. Record missing or stale context instead of compensating with assumptions.
- Produce the role's required JSON artifacts and validate them before handoff.
- Keep each scope item in one state: `ready`, `in_progress`, `implemented`, `held`, `rejected`, or `done`.
- A held scope item remains held until the knowledge keeper records evidence that resolves every blocking question.
- Send the knowledge keeper a summary of evidence learned, decisions made, files changed, tests run, failures, and remaining uncertainty.
- On an unexpected agent exit, invalid or missing artifact, stuck process, or dashboard/runtime contract error, notify Knowledge Keeper and route diagnosis to Health Check Agent. Use only the configured deterministic repair runner automatically; source changes remain Developer-owned.
- A failed agent must return its agent ID, stage, error or exit code, last completed action, and diagnostic evidence. Knowledge Keeper persists this with `scripts/Write-AgentFailure.ps1`, immediately runs `scripts/Invoke-EcosystemHealthCheck.ps1 -Repair`, and starts `scripts/Start-AgentHealthRecovery.ps1` when automatic recovery is enabled. Do not wait for a manual dashboard refresh to register the failure.
