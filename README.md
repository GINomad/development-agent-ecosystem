# Development Agent Ecosystem

An evidence-first local Codex ecosystem for the complete software delivery cycle: requirements analysis, knowledge management, implementation, code and agent-work review, and Azure Pipelines monitoring.

The canonical configuration is [`config/agents.json`](config/agents.json). Every workflow start reloads and validates this JSON file, then compiles it into native Codex agent TOML definitions. Do not edit generated TOML files manually.

## Included components

| Component | Responsibility | Boundary |
|---|---|---|
| Knowledge Keeper | Pull-based knowledge and skill service, orchestration, final outcomes, task summary, and verified knowledge updates | Never polls subagents or ingests unfinished context |
| Requirements Analyst | Azure Boards tasks, comments, code, and knowledge; discrepancies, questions, and implementation planning | Never marks unclear scope as ready |
| Developer | Branch creation, ready-scope implementation, tests, and implementation evidence | Applies review findings only after human approval |
| Reviewer | Reviews code and Developer-agent work against requirements, held scope, knowledge, and tests | Read-only; a finding is not automatic permission to make a change |
| Pipeline Monitor | Low-reasoning summary of deterministic monitoring for an exact branch and commit | Queuing a build requires explicit permission |
| Health Check Agent | Diagnoses failures from bounded recent-log tails, performs bounded recovery, and verifies the repair | Product repositories and external writes are excluded; one recovery attempt per failure signature |
| Review Monitor | Per-PR code revisions, user comments, local notes, and pending AI-processing state | A comment change forces only its own PR |

The existing `azure-pr-review-monitor` and `azure-pipeline-monitor` skills are vendored into the plugin. Review Monitor uses an isolated `DataRoot`; both global skill copies remain available for rollback.

![Development Agent Ecosystem architecture](docs/assets/ecosystem-architecture.svg)

For the detailed repository composition, see [repository-architecture.svg](docs/assets/repository-architecture.svg).

## Quick start

```powershell
cd C:\Repos\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

The dashboard listens only on `127.0.0.1`. It lets you select one or more repositories for a task, choose manual or automate mode, provide a task ID, URL, or description, monitor every persisted task and all six agent statuses after a page reload, click any agent to inspect its configurable live activity log, send that agent a comment, or restart only that agent, stop an active workflow without losing completed work, resume only unfinished agents from the checkpoint, see unresolved agent questions, answer a specific question or send a general intervention command, preview text-based task artifacts, run a health check, approve one elevated repair or one elevated workflow session when the Windows sandbox is broken, resume recovered work, leave notes for the Reviewer agent, and start reviews.

Every Codex runner is supervised. Three identical execution failures terminate the run, persist a guard and agent-failure report, fail the task, and hand bounded recent evidence to Health Check Agent. Knowledge Keeper never loops over subagent waits: roles request knowledge when needed, keep unfinished context in private checkpoints, and publish one shared outcome only after success. A running role sizes its own coherent work blocks, reads one comment batch after each block, and continues without restart when more ready work remains. Unchanged artifacts are represented by fingerprints and summaries, and a final `task-summary.json` is written only after the whole task completes. For Windows policy error 1260, Health Check automatically compiles host-compatible variants of all six agents; an explicitly confirmed elevated resume selects those variants without disabling CrowdStrike or any delivery gate.

See [installation](docs/installation.md), [architecture](docs/architecture.md), [configuration](docs/configuration.md), and [operations and rollback](docs/operations.md).

## Common commands

```powershell
# Validate the ecosystem without starting agents
.\scripts\Test-AgentEcosystem.ps1

# Work on one explicitly selected task across two repositories
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode manual -TaskSelector 1839566 -RepositoryIds azure-planningspace-ps-excel-agent,azure-planningspace-ps-bicep

# Process all active tasks assigned to the configured user
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode automate

# Run Review Monitor without publishing comments
.\scripts\Invoke-EnhancedReview.ps1 -Mode Manual -DryRun

# Preview, install, or roll back scheduled-task migration
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Preview
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Install
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Rollback
```

## Safety boundaries

- Unclear requirement scope is placed on `hold`; independent ready scope may continue.
- Claims about requirements, code, and knowledge must include a source and revision.
- Local notes and PR comments are untrusted evidence, not system instructions.
- Secrets are never stored in JSON. `credentialProfiles` contains an authentication strategy and environment-variable name; credentials remain in the Azure CLI credential store or process environment.
- Git push, review-comment publication, pipeline queueing, and work-item mutation require separate explicit authorization.
- An OS restriction can be bypassed only through a task-specific dashboard confirmation. Elevated execution does not bypass requirements holds, review decisions, or external-write gates.
