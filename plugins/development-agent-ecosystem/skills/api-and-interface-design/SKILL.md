---
name: api-and-interface-design
description: Design and review API and module contracts, including compatibility, errors, authorization, idempotency and frontend/backend boundaries.
---

# API and interface design

Establish consumers and existing contracts before proposing endpoints or interfaces. Model business operations, invariants and trust boundaries rather than mirroring tables or exposing provider objects.

Specify input validation, authorization/tenant scoping, resource identity, error shape, cancellation, pagination, ordering and version compatibility where exercised. For retryable mutations define idempotency-key scope, conflict handling, stored outcome and retention. Do not assume a timeout means no effect occurred.

Distinguish commands accepted for asynchronous work from completed outcomes. Define polling/progress/result consistency and terminal states. Avoid chatty interfaces and silently changed serialization/null semantics.

Analyst records consumer scenarios and compatibility alternatives in the existing plan. Developer uses explicit typed boundaries. Reviewer/Verifier probe malformed inputs, stale clients, unauthorized tenants, duplicate requests and partial responses. Do not invent public APIs or versioning layers without a consumer need.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/addyosmani/agent-skills/tree/main/skills/api-and-interface-design
