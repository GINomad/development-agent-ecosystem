---
name: keep-task-knowledge
description: Curate verified task context, append per-task agent history, issue focused context packs, and update durable engineering knowledge with source and revision evidence. Use when orchestrating agents or resuming a task across sessions.
---

# Keep Task Knowledge

1. Reconstruct task state from the append-only ledger and referenced artifacts.
2. Select only relevant, verified knowledge for the recipient agent.
3. Create a context pack conforming to `config/schemas/context-pack.schema.json`. Maintain fingerprinted `artifactSummaries` and refresh only changed entries from `resume-plan.json`.
4. Dispatch without polling. Answer explicit knowledge and skill requests with the smallest verified bundle throughout delivery; this on-demand service does not require a final-publication command.
5. Accept a shared result only after the role completed and `Publish-AgentOutcome.ps1` validated every configured artifact. Never read private waiting or failed checkpoints.
6. Keep open questions and held scope visible until evidence resolves them.
7. Analyze successful outcomes for durable code rules or decisions. Promote review guidance to a scoped coding standard only when the human decision, successful implementation when applicable, and later clean review provide evidence; exclude bypassed, deferred, rejected, unresolved, speculative, and task-only comments. Publish knowledge only when it conforms to `config/schemas/knowledge-update.schema.json` and has all required evidence.
8. Write `task-summary.json` only after the complete task succeeds and Orchestrator routes the validated final-publication command. Keep hypotheses and task-local observations out of shared durable knowledge.
