# Task protocol

- Communicate material inputs and results through the knowledge keeper.
- Work under one stable task ID. Use `${STATE_ROOT}/tasks/<task-id>` for private task history and runtime artifacts.
- Append concise events to `task-ledger.jsonl`; never rewrite prior events.
- Read `context-pack.json` before acting. Record missing or stale context instead of compensating with assumptions.
- Produce the role's required JSON artifacts and validate them before handoff.
- Keep each scope item in one state: `ready`, `in_progress`, `implemented`, `held`, `rejected`, or `done`.
- A held scope item remains held until the knowledge keeper records evidence that resolves every blocking question.
- Send the knowledge keeper a summary of evidence learned, decisions made, files changed, tests run, failures, and remaining uncertainty.

