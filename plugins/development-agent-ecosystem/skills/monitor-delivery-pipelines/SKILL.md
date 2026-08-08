---
name: monitor-delivery-pipelines
description: Integrate exact-branch and exact-commit Azure pipeline monitoring into the task workflow and return terminal results and failure evidence to the knowledge keeper. Use only after an authorized push or an explicit pipeline monitoring request.
---

# Monitor Delivery Pipelines

1. Require an exact branch and full commit SHA.
2. Use `$azure-pipeline-monitor` when that installed dependency is available.
3. Apply repository-specific queue permissions; never infer a build or deployment definition.
4. Wait for every exact-SHA run to reach a terminal state.
5. Treat failed, partially succeeded, canceled, and timed-out runs as non-success.
6. Write output conforming to `config/schemas/pipeline-result.schema.json`.
7. Return run links, results, and focused failed-task evidence to the knowledge keeper.

