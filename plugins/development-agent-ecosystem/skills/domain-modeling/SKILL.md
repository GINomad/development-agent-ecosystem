---
name: domain-modeling
description: Model domain language, invariants, ownership and lifecycle using verified project evidence. Use for domain analysis, aggregate boundaries and business-rule review.
---

# Domain modeling

Load the selected project's local skills and revision-bound knowledge; distinguish main-product facts from companion repositories. Keep confirmed terms, assumptions and unresolved questions separate. Never infer legal policy or product behavior from a generic industry skill.

Identify entities, value semantics, commands, facts, invariants, lifecycle transitions, temporal rules, aggregate/transaction boundaries and source-of-truth ownership only where relevant. A small CRUD feature may need a glossary and validation rule rather than a domain framework.

Use the same language in requirements, code, API and tests; resolve collisions through bounded contexts instead of globally renaming unrelated concepts. Make identity versus display values, business timestamps versus observation timestamps, units/precision and tenant boundaries explicit.

Analyst links each invariant to evidence and SCN acceptance scenarios, holding unsupported rules. Developer preserves invariants across every entry point. Reviewer searches for duplicated/inconsistent policy and invalid states. Verifier independently challenges a boundary or transition with a counterexample.

Store business glossaries, decisions, examples and source bindings only in the local project knowledge root. Promote only demonstrably reusable engineering guidance to common skills.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/mattpocock/skills/tree/main/skills/engineering/domain-modeling
- https://github.com/codewithmukesh/dotnet-claude-kit/tree/main/skills/ddd
