---
name: architecture-decision-records
description: Record durable architectural choices with alternatives, consequences and revisit triggers. Use when a material boundary or technology decision needs a maintained rationale.
---

# Architecture decision records

Follow the repository's ADR convention. Record a decision when it affects contracts, ownership, deployment, data consistency or costly-to-reverse structure; keep small task-local choices inline in the specification-practices plan.

Include status, context/requirements, observed evidence, simple/default alternative, selected option, rejected alternatives, consequences, validation, rollback/evolution and revisit triggers. Link the existing plan and requirement IDs rather than duplicating them. Supersede decisions explicitly; do not rewrite history to disguise changes.

Project/domain decisions and source evidence stay in the local project block. Common ecosystem process decisions may be versioned with common skills. An ADR documents a choice; it does not authorize implementation or release held requirements.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/affaan-m/ECC/tree/main/skills/architecture-decision-records
