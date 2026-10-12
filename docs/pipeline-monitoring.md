# Pipeline monitoring and ownership

This page is the operator view of the pipeline contract. The machine-readable source of truth is `pipeline` in `config/agents.json`; `config/schemas/agents.schema.json`, semantic validation in `scripts/AgentEcosystem.psm1`, and `scripts/Test-AgentEcosystem.ps1` fail closed when the contract drifts.

## Policy setup

Run `scripts/Get-PipelinePolicySetup.ps1` during the first configuration check. The same three choices must be presented by the LLM-guided setup:

| Mode | Behavior | Required developer input |
|---|---|---|
| `disabled` | No pipeline monitoring, PR lifecycle, push, or queueing | Explicit confirmation that pipelines are not applicable |
| `observe-only` | Exact-SHA observation and optional PR lifecycle; no push or queueing | Repository IDs, optional observed definition IDs, deployment definition IDs, and PR-monitoring preference |
| `guarded-delivery` | Reviewed branch delivery plus ordered allowlisted build queueing | Observe-only inputs plus the allowed remote, protected branches, ordered build-only queue IDs, and deployment IDs |

`pipeline.policy.configurationStatus` remains `unconfigured` until the developer supplies the required non-secret information. An unconfigured policy must use `mode=disabled` with all pipeline switches off. Installation refuses that pending state, while Health Check reports the choices and required action. An explicit opt-out uses `configurationStatus=disabled` and `mode=disabled`.

Every `pipeline.repositories[]` item separates `definitionIds`, `autoQueueDefinitionIds`, and `deploymentDefinitionIds`. A definition may be observed and classified as a deployment, but any overlap between deployment and auto-queue lists fails validation. The setup assistant must never infer a build/deployment classification from a name or an existing run.

## Agent ownership

`pipeline.ownership` assigns every pipeline transition to one configured agent. Task text, comments, and similarly named repositories cannot override this map.

| Configuration key | Agent | Responsibility |
|---|---|---|
| `monitorAgentId` | `pipeline_monitor` | Guarded working-branch delivery, exact-SHA build observation, bounded failed-log extraction, and task-PR status |
| `productRemediationAgentId` | `developer` | Product code, tests, and product pipeline YAML supported by `code` or `test` failure evidence |
| `remediationReviewAgentId` | `reviewer` | Candidate review, complete coverage matrix, and stable finding lifecycle for every remediation |
| `reviewVerificationAgentId` | `review_verifier` | Independent falsification of coverage, findings, and lifecycle bound to the exact review SHA before delivery or rework decisions |
| `exceptionRoutingAgentId` | `orchestrator` | Routing of infrastructure, credential, no-run, unknown, limit-reached, and terminal PR outcomes |
| `ecosystemRecoveryAgentId` | `health_check` | Ecosystem runtime, scripts, configuration, skills, dashboard, or control-plane defects only |
| `completionAgentId` | `knowledge_keeper` | Final evidence-backed task history and knowledge publication after Orchestrator validates completion |

The normal remediation loop is `pipeline_monitor -> developer -> reviewer -> review_verifier -> pipeline_monitor`. Coverage/lifecycle rejection loops `review_verifier -> reviewer`; an approved independently confirmed product finding loops `review_verifier -> developer`. A successful completed PR follows `pipeline_monitor -> orchestrator -> knowledge_keeper`.

## Repository and definition matrix

| Repository ID | Azure DevOps location | Observed definitions | Auto-queue order | Monitor |
|---|---|---|---|---|
| `azure-planningspace-ps-excel-agent` | Configured locally | Exact-SHA runs; an empty `definitionIds` list permits discovery | Ordered local build allowlist | `pipeline_monitor` |
| `azure-planningspace-ps-bicep` | `Aucerna / PlanningSpace / ps-bicep` | Triggered exact-SHA runs; empty `definitionIds` means discovery is not restricted to one definition | None; observation only | `pipeline_monitor` |
| `azure-palantirplugins-ps-app-delfi` | `palantir-consulting / PalantirPlugins / ps-app-delfi` | Definition `17` for the exact SHA | None; definition 17 is observation only | `pipeline_monitor` |

Deployment definition IDs are local configuration and must never be inferred. An empty auto-queue list is not permission to queue a pipeline.

## Exact-SHA lifecycle

1. Pipeline Monitor may call `Invoke-ReviewedBranchDelivery.ps1` only after Review Verifier passes every coverage/lifecycle claim for the exact review SHA and the review is clean, or every remaining independently confirmed product finding is explicitly rejected or bypassed into linked exact-review-bound open task-local debt. Verifier-rejected findings are auditable but never enter this gate.
2. The delivery script permits only a clean, non-base, non-force, non-tag push to the configured `origin`, then verifies the full remote SHA.
3. `Invoke-PostPushPipeline.ps1` accepts the repository ID, branch, full pushed SHA, and pre-push UTC timestamp. The native watcher ignores branch-only and mismatched-commit runs.
4. Only an allowlisted build definition may be queued. Ordered definitions are fail-closed: a later definition is queued only after the earlier exact-SHA definition succeeds.
5. `code` or `test` failures produce a deduplicated Developer request. Reviewer must review the resulting change and Review Verifier must independently pass the exact artifact before Pipeline Monitor observes the replacement SHA. The loop is limited to three cycles.
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
  "autoQueueDefinitionIds": [],
  "deploymentDefinitionIds": []
}
```

Use `definitionIds` for exact-SHA runs that may be observed. Keep `autoQueueDefinitionIds` empty unless every listed ID is a confirmed build-only definition and its order is intentional. Do not duplicate the ownership object per repository; all configured repositories use the canonical role chain above.

After any change, run:

```powershell
.\scripts\Test-AgentEcosystem.ps1
```

Do not weaken schema, semantic validation, exact-origin verification, independent review-verification gates, human decision gates, or queue allowlists to make a new repository pass.
