# Agent token usage

Every provider invocation launched by `Start-DevelopmentWorkflow.ps1` writes task-local `token-usage.jsonl` after the invocation, including failures and interrupted streams when counters are available. All workflow roles and the separate automatic Health Check recovery invocation use the same collector. Collection occurs before artifact validation and continuation, so a later workflow error cannot duplicate the provider usage.

Each record identifies the task, task revision, agent, workflow `runId` (`iterationId`), role `attemptId`, provider attempt, provider, requested model, reported model, and counter source. A workflow run identifies an execution iteration; task revision separately identifies a requirements/reopen revision. A new restart produces a new attempt. Codex capacity fallback produces separate provider attempts and records the fallback model. Provider switches start a new role attempt.

Claude terminal `modelUsage` counters are authoritative and preserve actual model IDs, including models used by subagents. Terminal `usage` is used only when per-model counters are absent. For interrupted Claude runs, only the latest usage snapshot per message ID is counted and records are marked `partial`. Codex counts `turn.completed` events. Copilot reads its per-invocation usage output file when recognized counters are available. Unknown formats and missing counters remain null and are marked unavailable when input/output counters cannot be read; no token amounts are estimated.

Claude total tokens include input, output, cache read and cache creation counters. Codex input already includes cached input, so cached tokens are not added again. Claude totals are null if a required cache counter is missing. Persisting the same provider attempt/model twice is idempotent under a file lock. Logging failures produce a workflow warning without changing the agent's outcome.

Query totals with:

```powershell
./scripts/Get-AgentTokenUsage.ps1 -TaskRoot 'path/to/state/tasks/task-id' -GroupBy agent
./scripts/Get-AgentTokenUsage.ps1 -TaskRoot 'path/to/state/tasks/task-id' -GroupBy iteration
./scripts/Get-AgentTokenUsage.ps1 -TaskRoot 'path/to/state/tasks/task-id' -GroupBy attempt
```

The result exposes raw `Records` and grouped `Summary`. Summary totals remain null if any member lacks that counter; `knownInputTokens` and other `known*` fields expose only observed counts. Partial and unavailable record counts make incompleteness visible. No historical usage is synthesized. Older executions are not automatically backfilled.

This local installation pins all four Claude complexity tiers to `claude-sonnet-5-5` with reasoning effort `none`. Complexity classification still runs; it no longer changes the Claude model. Other provider mappings are unaffected. Running invocations keep their already selected model; the mapping applies to subsequent invocations.
