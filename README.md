# Development Agent Ecosystem

An evidence-first local Codex ecosystem for the complete software delivery cycle: requirements analysis, knowledge management, implementation, code and agent-work review, and Azure Pipelines monitoring.

The canonical configuration is [`config/agents.json`](config/agents.json). Every workflow start reloads and validates this JSON file, then compiles it into native Codex agent TOML definitions. Do not edit generated TOML files manually.

## Included components

| Component | Responsibility | Boundary |
|---|---|---|
| Knowledge Keeper | Orchestration, context packs, task history, and verified knowledge updates | Never publishes assumptions as knowledge |
| Requirements Analyst | Azure Boards tasks, comments, code, and knowledge; discrepancies, questions, and implementation planning | Never marks unclear scope as ready |
| Developer | Branch creation, ready-scope implementation, tests, and implementation evidence | Applies review findings only after human approval |
| Reviewer | Reviews code and Developer-agent work against requirements, held scope, knowledge, and tests | Read-only; a finding is not automatic permission to make a change |
| Pipeline Monitor | Pipelines for an exact branch and commit, including failed task logs | Queuing a build requires explicit permission |
| Review Monitor | Active PRs, code revisions, user comments, and local reviewer notes | Self-authored PRs can be excluded by configuration |

The existing `azure-pr-review-monitor` and `azure-pipeline-monitor` skills are vendored into the plugin. Review Monitor uses an isolated `DataRoot`; both global skill copies remain available for rollback.

![Development Agent Ecosystem architecture](docs/assets/ecosystem-architecture.svg)

## Quick start

```powershell
cd C:\Repos\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

The dashboard listens only on `127.0.0.1`. It lets you select manual or automate mode, provide a task ID, URL, or description, select an assigned task, leave a note for the Reviewer agent, and start a review.

See [installation](docs/installation.md), [architecture](docs/architecture.md), [configuration](docs/configuration.md), and [operations and rollback](docs/operations.md).

## Common commands

```powershell
# Validate the ecosystem without starting agents
.\scripts\Test-AgentEcosystem.ps1

# Work on one explicitly selected task
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode manual -TaskSelector 1839566

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
