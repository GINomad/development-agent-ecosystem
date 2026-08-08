---
name: coordinate-delivery
description: Orchestrate requirements, knowledge, implementation, review approval, and pipeline monitoring with explicit artifact gates and per-task history. Use for end-to-end software delivery tasks handled by the development agent ecosystem.
---

# Coordinate Delivery

1. Use the knowledge keeper as the primary agent and communication hub.
2. Run requirements analysis before any implementation.
3. Allow implementation only for ready scope; retain partial holds for unresolved scope.
4. Require implementation plan and result artifacts before review.
5. Require read-only review against requirements and agent behavior.
6. Pause review fixes until a human records explicit finding decisions.
7. After an authorized push, invoke exact-commit pipeline monitoring.
8. Batch pending comments at one checkpoint; do not restart once per comment or poll a role for progress.
9. Keep working context private for waiting or failed roles. Publish only validated successful outcomes to shared history.
10. Finish and write the task summary only when required scope is done; a task with held questions remains waiting, not completed.
