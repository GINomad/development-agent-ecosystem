# PlanningSpace pipelines

Organization and project endpoints are supplied by local configuration.
Project: `PlanningSpace`

| Definition | Repository | Purpose | Trigger |
|---|---|---|---|
| `814` | `ps-excel-agent` | Standard UI/.NET build and Web App artifact | `main` only |
Pipeline definition IDs and deployment parameters are intentionally kept in local machine configuration.

## Deployment safety

Deployment definitions require explicit locally supplied values:

- `environment`: `Dev`, `QA`, `UAT`, or `Prod`
- `instanceNumber`: three digits, not `000`
- `imageTag`: immutable Docker build ID preferred over `latest`

The agent may automatically queue only the ordered build definitions present in the local allowlist. Every preceding definition must succeed for the exact commit before the next definition is queued and accepted. Never infer or automatically queue a deployment definition; confirm deployment intent and parameters first.

## Expected behavior after feature pushes

Trigger behavior and ordered definition IDs are local operational data. Feature-branch delivery passes the configured `autoQueueDefinitionIds`; the watcher ignores earlier runs for later sequence steps and advances only after exact-SHA success.
