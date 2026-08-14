# PlanningSpace pipelines

Organization: `https://dev.azure.com/Aucerna`
Project: `PlanningSpace`

| Definition | Repository | Purpose | Trigger |
|---|---|---|---|
| `814` | `ps-excel-agent` | Standard UI/.NET build and Web App artifact | `main` only |
| `892` | `ps-excel-agent` | Docker build and ACR push | None; manual |
| `891` | `ps-bicep` | Excel Agent infrastructure/container deployment | None; manual |

## Deployment safety

Definition `891` requires explicit values:

- `environment`: `Dev`, `QA`, `UAT`, or `Prod`
- `instanceNumber`: three digits, not `000`
- `imageTag`: immutable Docker build ID preferred over `latest`

The agent may automatically queue build definitions `814` then `892` after a `ps-excel-agent` push. Definition 814 must succeed for the exact commit before a new 892 is queued and accepted. Never automatically queue `891`; confirm deployment intent and parameters first. For the current DEV instance, the established values are `Dev`, `001`, and the successful run ID from definition `892` as `imageTag`.

## Expected behavior after feature pushes

Definitions `892` and `891` have `trigger: none`. Definition `814` only triggers automatically for `main`, so feature-branch delivery invokes the watcher with `-AutoQueueDefinitionIds 814,892`. The watcher ignores an earlier 892 for sequence acceptance, queues 814 when needed, and queues a new 892 only after exact-SHA 814 success.
