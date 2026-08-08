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

The agent may automatically queue build definition `892` after a `ps-excel-agent` push when no run exists for the exact commit. Never automatically queue `891`; confirm deployment intent and parameters first. For the current DEV instance, the established values are `Dev`, `001`, and the successful run ID from definition `892` as `imageTag`.

## Expected behavior after feature pushes

Definitions `892` and `891` have `trigger: none`. Definition `814` only triggers for `main`. After a `ps-excel-agent` push, invoke the watcher with `-AutoQueueDefinitionIds 892`; it queues `892` only when an exact-SHA run does not already exist and also discovers any `814` run for that commit.