---
name: coordinate-delivery
description: Route and coordinate requirements, knowledge, implementation, review approval, and pipeline monitoring with targeted restarts, explicit artifact gates, and per-task history. Use for end-to-end software delivery and workflow-comment handling in the development agent ecosystem.
---

# Coordinate Delivery

1. Use Workflow Orchestrator as the task/comment control plane. Use Knowledge Keeper only as an on-demand verified knowledge service and final curator.
2. Route new task intake to Requirements Analyst before implementation. Route later comments to the smallest sufficient responsible agent set.
3. Persist routing without changing another agent's status. When new evidence changes completed, waiting, interrupted, or failed work, request a targeted restart and let the trusted host start that agent after the Orchestrator succeeds.
4. Allow implementation only for ready scope; retain partial holds for unresolved scope.
5. Require implementation plan and result artifacts before read-only review against requirements and agent behavior.
6. Pause review fixes until a human records explicit finding decisions.
7. After an authorized push, invoke exact-commit pipeline monitoring.
8. Batch pending comments at one checkpoint. Never poll roles, repeatedly call wait, or use collaboration wait when no child agent is running.
9. After publishing the current role outcome, return control immediately to the trusted host continuation. Do not idle-wait for the next role or start it inside the same targeted invocation.
10. Keep working context private for waiting or failed roles. Publish only validated successful outcomes to shared history.
11. Finish and write the task summary only when required scope is done; a task with held questions remains waiting, not completed.
