---
name: messaging-and-reliability
description: Design and review retries, idempotency, async jobs, messaging, outbox and compensation using evidenced failure and consistency requirements.
---

# Messaging and reliability

Map side effects and failure boundaries first: database commit, provider acceptance, message delivery, acknowledgement and caller observation. Classify transient versus permanent errors and unknown outcomes. Retries must respect idempotency and business deadlines.

Use bounded retry/backoff with jitter, cancellation and timeouts owned at the appropriate layer. Avoid retry multiplication across client, service and worker. Define deduplication scope, retention, concurrency claims and replayed results; do not promise end-to-end exactly-once processing.

Use outbox/inbox only when durable state plus effect publication requires it. Model poison messages, ordering, competing consumers, recovery and monitoring. Sagas require explicit business compensation and irrecoverable/manual states.

For async jobs establish persistence requirement, restart behavior, capacity/backpressure, progress/result consistency and cleanup. An in-memory job manager is acceptable only under its evidenced durability/deployment requirements.

Analyst ties guarantees to scenarios and alternatives. Developer tests failure windows and replay. Reviewer/Verifier probe crash-after-effect, stale approval, duplicate delivery, cancellation races, lease expiry and multi-instance behavior. Do not introduce a broker, saga or distributed lock without an observed need.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/codewithmukesh/dotnet-claude-kit/tree/main/skills/messaging
- https://github.com/codewithmukesh/dotnet-claude-kit/tree/main/skills/resilience
