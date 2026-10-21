---
name: design-patterns
description: Select and assess design patterns against concrete change, state, dependency and failure pressures. Use when planning, implementing or reviewing behavior or structural abstractions.
---

# Design patterns

Use architecture-and-pattern-selection for system boundaries and apply-engineering-principles for proportionality. Identify the concrete pressure before choosing a pattern; compare a direct function, conditional, local composition or existing abstraction first.

| Pattern | Useful signal | Check before adopting |
| --- | --- | --- |
| Strategy / Policy | Several evidenced algorithms or policy variants | A small stable conditional may be clearer; keep policy inputs explicit |
| Factory | Runtime construction with real lifetime/selection rules | Prefer ordinary DI registration when construction is static |
| Adapter / Facade | A foreign contract needs translation or a cohesive boundary | Preserve errors, cancellation and ownership; avoid pass-through wrappers |
| Decorator | Orthogonal composable behavior around a stable contract | Make ordering, repeated application and exception behavior explicit |
| State / state machine | Legal transitions, guards and temporal invariants | Persist transition/version atomically; test rejected and replayed transitions |
| Specification | Reused composable domain predicates | Verify query translation; avoid hiding I/O or building a DSL for one filter |
| Repository / Unit of Work | Existing aggregate/data boundary and transaction ownership | EF DbContext already provides these features; do not add generic wrappers automatically |
| Mediator | Useful request isolation and shared pipeline behavior | Extra navigation/handlers must buy observable value |
| Observer / domain event | Several independent reactions to a business fact | Transaction commit, ordering, duplicate handling and subscription lifetime |
| Outbox / Inbox | State and message publication must survive partial failure | Atomic persistence, retry ownership, deduplication and retention |
| Saga | A real multi-transaction business process needs compensation | Compensation is business behavior; it is not a distributed rollback |
| Builder | Complex valid construction with many meaningful combinations | Prefer constructor/record/options for simple inputs |

Actively look for repeated policy switches, illegal state combinations, provider leakage, duplicate effect orchestration and untestable I/O coupling. Recommend a pattern only when it improves those observed paths within authorized scope.

Analyst records applicability and alternatives in the existing plan. Developer preserves contracts and proves lifecycle/error behavior. Reviewer tests both unnecessary abstraction and missed opportunities, with concrete costs. Verifier tries a simpler counter-design and a failure-path counterexample before confirming a finding. A hypothetical future requirement is not evidence.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/wshobson/agents/tree/main/plugins/backend-development/skills/architecture-patterns
- https://github.com/codewithmukesh/dotnet-claude-kit/tree/main/skills/ddd
