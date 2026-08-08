---
name: keep-task-knowledge
description: Curate verified task context, append per-task agent history, issue focused context packs, and update durable engineering knowledge with source and revision evidence. Use when orchestrating agents or resuming a task across sessions.
---

# Keep Task Knowledge

1. Reconstruct task state from the append-only ledger and referenced artifacts.
2. Select only relevant, verified knowledge for the recipient agent.
3. Create a context pack conforming to `config/schemas/context-pack.schema.json`.
4. Record each handoff and returned result in `task-ledger.jsonl`.
5. Keep open questions and held scope visible until evidence resolves them.
6. Publish durable knowledge only when it conforms to `config/schemas/knowledge-update.schema.json` and has all required evidence.
7. Keep hypotheses and task-local observations out of shared durable knowledge.

