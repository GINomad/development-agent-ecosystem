# Pipeline monitoring and ownership

This page is the operator view of the pipeline contract. The machine-readable source of truth is `pipeline` in `config/agents.json`; `config/schemas/agents.schema.json`, semantic validation in `scripts/AgentEcosystem.psm1`, and `scripts/Test-AgentEcosystem.ps1` fail closed when the contract drifts.

## Agent ownership

`pipeline.ownership` assigns every pipeline transition to one configured agent. Task text, comments, and similarly named repositories cannot override this map.

| Configuration key | Agent | Responsibility |
|---|---|---|
| `monitorAgentId` | `pipeline_monitor` | Guarded working-branch delivery, exact-SHA build observation, bounded failed-log extraction, and task-PR status |
| `productRemediationAgentId` | `developer` | Product code, tests, and product pipeline YAML supported by `code` or `test` failure evidence |
| `remediationReviewAgentId` | `reviewer` | Review of every remediation before a replacement commit can be delivered and monitored |
| `exceptionRoutingAgentId` | `orchestrator` | Routing of infrastructure, credential, no-run, unknown, limit-reached, and terminal PR outcomes |
| `ecosystemRecoveryAgentId` | `health_check` | Ecosystem runtime, scripts, configuration, skills, dashboard, or control-plane defects only |
| `completionAgentId` | `knowledge_keeper` | Final evidence-backed task history and knowledge publication after Orchestrator validates completion |

The normal remediation loop is `pipeline_monitor -> developer -> reviewer -> pipeline_monitor`. A successful completed PR follows `pipeline_monitor -> orchestrator -> knowledge_keeper`.

## Repository and definition matrix

| Repository ID | Azure DevOps location | Observed definitions | Auto-queue order | Monitor |
|---|---|---|---|---|
| `azure-planningspace-ps-excel-agent` | `Aucerna / PlanningSpace / ps-excel-agent` | Exact-SHA runs; an empty `definitionIds` list permits discovery | `814`, then a newly queued `892` only after 814 succeeds | `pipeline_monitor` |
| `azure-planningspace-ps-bicep` | `Aucerna / PlanningSpace / ps-bicep` | Triggered exact-SHA runs; empty `definitionIds` means discovery is not restricted to one definition | None; observation only | `pipeline_monitor` |
| `azure-palantirplugins-ps-app-delfi` | `palantir-consulting / PalantirPlugins / ps-app-delfi` | Definition `17` for the exact SHA | None; definition 17 is observation only | `pipeline_monitor` |

Deployment definition `891` is forbidden by semantic validation and must never appear in `autoQueueDefinitionIds`. An empty auto-queue list is not permission to infer or queue a pipeline.

## Exact-SHA lifecycle

1. Pipeline Monitor may call `Invoke-ReviewedBranchDelivery.ps1` only after the review gate is clean or every remaining product finding is explicitly rejected or bypassed into linked open task-local debt.
2. The delivery script permits only a clean, non-base, non-force, non-tag push to the configured `origin`, then verifies the full remote SHA.
3. `Invoke-PostPushPipeline.ps1` accepts the repository ID, branch, full pushed SHA, and pre-push UTC timestamp. The native watcher ignores branch-only and mismatched-commit runs.
4. Only an allowlisted build definition may be queued. Ordered definitions are fail-closed: a later definition is queued only after the earlier exact-SHA definition succeeds.
5. `code` or `test` failures produce a deduplicated Developer request. Reviewer must approve the resulting change before Pipeline Monitor observes the replacement SHA. The loop is limited to three cycles.
6. Infrastructure, credential, no-run, unknown, and limit-reached outcomes return to Orchestrator. Health Check is selected only when evidence points to the ecosystem itself.
7. A successful build does not close the task. Pipeline Monitor synchronizes the task PR; a completed PR returns to Orchestrator, which validates terminal evidence before routing final publication to Knowledge Keeper.

Repeated Azure polling and failure classification are deterministic and do not consume model turns. Agent work begins only for analysis, remediation, routing, or publication that the persisted outcome requires.

A failed Azure run can stop during provider-side validation before jobs start. Pipeline Monitor reads run-level `validationResults` first and does not require timeline or log endpoints in that case; it persists the validation error, infrastructure classification, and a reasoned human-intervention recommendation.

## Changing pipeline coverage

For an existing managed repository, edit its matching object in `pipeline.repositories[]`:

```json
{
  "repositoryId": "azure-project-repository",
  "definitionIds": [123],
  "autoQueueDefinitionIds": []
}
```

Use `definitionIds` for exact-SHA runs that may be observed. Keep `autoQueueDefinitionIds` empty unless every listed ID is a confirmed build-only definition and its order is intentional. Do not duplicate the ownership object per repository; all configured repositories use the canonical role chain above.

After any change, run:

```powershell
.\scripts\Test-AgentEcosystem.ps1
```

Do not weaken schema, semantic validation, exact-origin verification, review gates, or queue allowlists to make a new repository pass.
