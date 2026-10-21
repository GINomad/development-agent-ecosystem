---
name: architecture-and-pattern-selection
description: Choose and review architectural boundaries and styles using repository evidence and current requirements. Use in analysis, implementation planning, structural changes, and architecture review.
---

# Architecture and pattern selection

Apply the existing apply-engineering-principles skill. Establish repository and runtime boundaries, current stack/version, transactions, scale, latency, security, deployment ownership, and accepted domain invariants from first-party evidence. Read only relevant technology skills and the selected project's local skills.

For a material decision, compare the current/simple implementation with plausible alternatives. State the observed problem, evidence, chosen boundary, rejected alternatives, added dependencies/indirection, test strategy, migration/rollback cost, and conditions for revisiting the decision. Inline reasoning is enough for small changes; write an ADR only for durable cross-cutting decisions.

| Option | Evidence that can justify it | Cost to challenge |
| --- | --- | --- |
| Layered application | Established dependency direction and cohesive application logic | Pass-through layers and anemic wrappers |
| Vertical slice | Features change independently and have distinct use cases | Duplicated policy and inconsistent cross-cutting behavior |
| Hexagonal / ports and adapters | Domain decisions need isolation from real variable I/O or test seams | One-to-one interfaces with no meaningful boundary |
| DDD / bounded contexts | Conflicting terminology, invariants or ownership across domains | Aggregates and events for simple CRUD |
| Modular monolith | Clear ownership with useful in-process transactions | Cyclic module dependencies and shared mutable internals |
| Microservices | Independent deployment/ownership or measured isolation/scaling need | Distributed transactions, operations and contract evolution |
| CQRS / event-driven | Read/write models or asynchronous business processes truly differ | Dual consistency models, replay and ordering complexity |

Do not prescribe microservices, CQRS, event sourcing, a generic repository or a mediator by default. Distinguish ordinary audit records from an event-sourced source of truth. Confirm data ownership and failure semantics before introducing asynchronous boundaries.

## Role application

- Analyst: include this comparison in the existing specification-practices plan; link it to requirementIds, SCN scenarios, ready/held scope, source revision and accepted knowledge. Preserve persisted practiceVersion. Do not start a competing Spec Kit workflow.
- Developer: implement the smallest justified option. Report deviations and new evidence; do not silently redesign held scope.
- Reviewer: challenge both excess structure and missing boundaries; compare with the simple option and cite a concrete correctness, evolution, operational or test cost. Lack of a named pattern alone is not a finding.
- Verifier: independently test the Reviewer's causal claim, including no-findings conclusions, with a distinct counterexample in the existing maintainability/correctness/concurrency coverage dimensions.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/codewithmukesh/dotnet-claude-kit/tree/main/skills/architecture-advisor
- https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture
