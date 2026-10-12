---
name: keep-task-knowledge
description: Curate verified task context, append per-task agent history, issue focused context packs, and update durable engineering knowledge with source and revision evidence. Use when orchestrating agents or resuming a task across sessions.
---

# Keep Task Knowledge

1. Reconstruct task state from the append-only ledger and referenced artifacts.
2. Select only relevant, verified knowledge for the recipient agent.
3. Build or reuse each revision-bound repository graph with `scripts/Update-RepositoryKnowledgeMap.ps1`. Audit the first unseen revision's manifests, architecture docs, entry points, tests, ownership boundaries, and dependency edges. Reuse unchanged fingerprints and inspect only the task-relevant graph neighborhood thereafter.
4. Create a context pack conforming to `config/schemas/context-pack.schema.json`. Include the repository map summaries and recommended starting paths, maintain fingerprinted `artifactSummaries`, and refresh only changed entries from `resume-plan.json`.
5. Dispatch without polling. Answer explicit knowledge and skill requests with the smallest verified bundle throughout delivery; this on-demand service does not require a final-publication command.
6. Accept a shared result only after the role completed and `Publish-AgentOutcome.ps1` validated every configured artifact. Never read private waiting or failed checkpoints.
7. Keep open questions and held scope visible until evidence resolves them.
8. Analyze successful outcomes for durable code rules or decisions. Evaluate every independently confirmed review comment about code organization, formatting, naming, access modifiers, member ordering, braces, testing style, maintainability, or engineering principles and, after successful implementation when applicable plus a later clean review and passing exact-SHA verification, publish it as a global or technology-scoped standard applicable across repositories. Keep business, domain, API, integration, and product-behavior knowledge repository-scoped. Exclude verifier-rejected, bypassed, deferred, rejected, unresolved, speculative, and explicitly task-only comments. Publish knowledge only when it conforms to `config/schemas/knowledge-update.schema.json` and has all required evidence.
9. Give every verified or superseded knowledge entry a matching `humanReadable` documentation item with the same ID and status, a reader-facing title, a plain-language explanation, and applicability. Exclude proposed or unresolved knowledge from end-user guidance. Give the final `task-summary.json` the same documentation-style view of delivery, decisions, verification, knowledge updates, and residual items.
10. Write `task-summary.json` only after the complete task succeeds and Orchestrator routes the validated final-publication command. Keep hypotheses and task-local observations out of shared durable knowledge.
