# Development Agent Ecosystem

An evidence-first local Codex ecosystem for the complete software delivery cycle: requirements analysis, knowledge management, implementation, candidate code review, independent review verification, and Azure Pipelines monitoring.

The canonical configuration is [`config/agents.json`](config/agents.json). Every workflow start reloads and validates this JSON file, then compiles it into native Codex agent TOML definitions. Do not edit generated TOML files manually.

## Included components

| Component | Responsibility | Boundary |
|---|---|---|
| Workflow Orchestrator | Classifies the requested outcome, chooses the narrowest configured execution mode, persists routing, dispatches only its permitted agent sequence, and coordinates capacity-limited leases for isolated per-task Git clones | Does not perform requirements, knowledge, implementation, review, pipeline, or health work; no-code/research-only boundaries, explicit targets, and approval gates are preserved |
| Knowledge Keeper | Pull-based knowledge and skill service, final outcomes, task summary, and verified knowledge updates | Never routes routine comments, polls subagents, or ingests unfinished context |
| Requirements Analyst | Azure Boards tasks, comments, code, and knowledge; discrepancies, questions, implementation planning, and a plain-language dashboard presentation of requirements and workflow | Never marks unclear scope as ready |
| Developer | Branch creation, ready-scope implementation, tests, and implementation evidence | Applies review findings only after human approval |
| Reviewer | Publishes candidate product/process findings, requirement traceability, the complete review-coverage matrix, and stable finding lifecycle (`new`, `unchanged`, `resolved`, `regressed`) | Source-code read-only; cannot read or write the verifier artifact, authorize implementation, or treat bypass as resolution |
| Review Verifier | Independently falsifies every coverage claim, active finding, and lifecycle transition against code/tests/history; binds verdicts to the exact review SHA | Separate read-only invocation and artifact; cannot rewrite Reviewer output, product code, human decisions, or debt records |
| Pipeline Monitor | Guarded independently verified branch push, exact-SHA build monitoring, bounded failure classification, Developer remediation, and task-PR completion evidence routed through Orchestrator | No stale/failed review verification, blocked coverage, base-branch/force/tag push; only JSON-allowlisted builds may be queued; deployments are never inferred |
| Health Check Agent | Owns bounded source-controlled ecosystem maintenance, diagnoses failures and explicit control-plane changes, drives ecosystem-only recovery, verifies it, and restarts only the affected agent | Product repositories and model-driven external writes are excluded; trusted host may publish only the exact verified repair commit under the configured origin/branch policy; one post-repair restart per failure signature |
| Review Monitor | Authored-or-assigned PR discovery, per-PR revisions, comments, local notes, reports, and shared PR status index | Native status polling uses no model; a content/comment change forces only its own PR |

The existing `azure-pr-review-monitor` and `azure-pipeline-monitor` skills are vendored into the plugin. Review Monitor uses an isolated `DataRoot`; both global skill copies remain available for rollback.

![Development Agent Ecosystem architecture](docs/assets/ecosystem-architecture.svg)

For the detailed repository composition, see [repository-architecture.svg](docs/assets/repository-architecture.svg). The current repository/definition allowlists and the agent responsibility chain are maintained in [pipeline monitoring and ownership](docs/pipeline-monitoring.md).

## Quick start

Model selection is cost-aware and configuration-driven. Before every Orchestrator or targeted-agent `codex exec`, `scripts/Resolve-AgentModelRoute.ps1` classifies bounded task evidence without an additional AI call, applies the agent's configured tier floor and cap, and persists the explainable decision in task-local `model-routing.json`. Unchanged inputs reuse the existing fingerprinted decision. The defaults are Luna/low for routine work, Terra/medium for standard work, Sol/high for complex work, and Sol/xhigh for critical work. Security, credentials, code signing, multi-repository work, large bounded evidence, a prior failure, or a post-repair retry can raise the tier.

For a new machine or developer, give this repository directory to an LLM and ask it to follow [SETUP_WITH_LLM.md](SETUP_WITH_LLM.md). The LLM reads the canonical documentation, conducts an interactive configuration interview, never requests secret values in chat, shows a redacted preview, and validates the setup before installation.

```powershell
cd C:\Repos\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

The loopback dashboard is full-width and persists across reloads. It supports multi-repository tasks, visible scheduler capacity and FIFO queue positions, per-task run/lease ownership, clone paths/branches/base SHAs, Orchestrator-routed general comments, explicit per-agent comments, per-agent live logs/outcomes, a human-readable Requirements Analyst view (requirements, acceptance criteria, workflow, and implementation plan), targeted restart with policy-scoped continuation, stop/checkpoint resume, visible input gates, safe artifact previews, a PR-style local diff with line-aware comments and durable Reviewer question/answer threads, the complete coverage matrix with verifier verdicts, finding lifecycle across revisions, a separate external-PR report tab, manual close with a required Knowledge Keeper update, and revision-preserving reopen from Requirements Analyst or Developer.

Every Codex runner is supervised. Three identical execution failures terminate the run, persist a guard and agent-failure report, fail the task, and hand bounded recent evidence to Health Check Agent. Initial, resume, targeted, recovery, and queued-task entry points all return successful role outcomes to one trusted host state machine; no UI flag is required to continue the configured chain. Before an agent is marked completed, outcome publication appends a durable continuation request. A deterministic scheduled reconciler detects a host that exited before dispatch, restarts only the missing next link, and uses per-task locking to prevent duplicate runs. It consumes no AI tokens unless an actual missing role must be launched. The host allows no more than sixteen handoffs and three repetitions of the same transition before failing closed into Health Check. Orchestrator routes intake without polling roles. The workspace coordinator admits up to `workflow.workspaceScheduling.maxActiveTasks` tasks concurrently (two by default) and preserves FIFO order when capacity is full. Each admitted task has exactly one controller lease and receives a full Git clone for every selected repository under the configured workspace root, with a unique task branch, immutable per-run execution context, and manifest recording canonical origin and base SHA. The lease records controller process identity and receives exact run/lease heartbeats; terminal or heartbeat-expired controller leases, including a crashed in-process runspace, are recovered without touching any other task. A stopped, failed, interrupted, or non-final completed checkpoint releases only its own lease; its clone and uncommitted work remain available for an explicit resume. After final closure is persisted with a completed task summary and no active lease, the clone is deleted, its manifest is marked `cleaned`, and a later explicit reopen provisions it again. The scheduler never executes in `repositories[].localWorkspace`, never shares a clone between tasks, and does not use Git worktrees or stashes. Knowledge Keeper answers bounded knowledge requests and consumes only successful outcomes. Roles keep unfinished context in private checkpoints and publish one shared outcome only after success. Reviewer and Review Verifier run separately and exchange only persisted public artifacts; the verifier never receives Reviewer private checkpoints or hidden reasoning. A running role sizes its own coherent work blocks, reads one direct or routed comment batch after each block, and continues without restart when more ready work remains. Unchanged artifacts are represented by fingerprints and summaries, and a final `task-summary.json` is written only after the whole task completes. The standing local policy selects host-compatible execution for all eight agents and Health recovery by default to avoid Windows error 1260; dashboard confirmation is an additional UI safeguard, not a new delivery authorization, and no requirement, review, credential, or external-write gate is disabled.

## Independent review contract

The delivery chain is `Developer → Reviewer → Review Verifier → decision/rework gate → Pipeline Monitor`. Reviewer publishes `review-result.json`; publication saves an immutable hash-addressed snapshot and updates `review-history-index.json`. The review must contain exactly ten coverage dimensions: requirements, correctness, security, regression, testing, maintainability, performance, concurrency, configuration/deployment, and documentation. Each dimension is `covered`, `not-applicable`, or `blocked` with evidence and notes.

Review Verifier starts as a separate read-only role and publishes `review-verification.json` bound to the lowercase SHA-256 and revision of the exact review artifact. It independently confirms or rejects every coverage claim and lifecycle transition, and marks each finding `confirmed`, `rejected`, or `needs-human` after a recorded falsification attempt. Coverage/lifecycle rejection returns work to Reviewer. A verifier-rejected finding remains visible for audit but cannot enter the human decision gate, authorize Developer rework, create bypass debt, or block delivery. Confirmed and escalated findings retain stable IDs across `new`, `unchanged`, `resolved`, and `regressed` revisions.

See [installation](docs/installation.md), [architecture](docs/architecture.md), [configuration](docs/configuration.md), [pipeline monitoring and ownership](docs/pipeline-monitoring.md), and [operations and rollback](docs/operations.md).

## Parallel tasks in the same repository

The task ID is the isolation boundary. Two tasks may target the same configured repository at the same time because each `(taskId, repositoryId)` pair receives its own full clone, unique task branch, manifest, immutable execution snapshots, controller lease, and task-local status history. A failure, stop, stale heartbeat, comment, or resume action for one task cannot advance or mutate the other task.

Start distinct work items from separate terminals, or create both from the dashboard:

```powershell
# Terminal 1
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode manual -TaskSelector 1839566 -RepositoryId azure-planningspace-ps-excel-agent

# Terminal 2
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode manual -TaskSelector 1839567 -RepositoryId azure-planningspace-ps-excel-agent
```

With the default capacity of two, both tasks are admitted. Additional tasks remain in the durable FIFO queue until a lease is released. Use the dashboard task selector to switch between them and verify each task's run ID, lease ID, clone path, branch, base SHA, status, agents, and timeline. Physical clone directory segments use Windows-safe keys; the task manifests and dashboard retain the full task and repository IDs. See the [parallel task runbook](docs/operations.md#parallel-task-runbook) for lifecycle and recovery details.

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

# After an authorized successful push, monitor/queue only the configured build and route code/test failures
.\scripts\Invoke-PostPushPipeline.ps1 -TaskId task-1839566 -RepositoryId azure-planningspace-ps-excel-agent -PushWasSuccessful -Branch feature/example -Commit <full-40-character-sha> -QueuedAfter <pre-push-utc>

# Preview the guarded non-force working-branch push without writing remotely
.\scripts\Invoke-ReviewedBranchDelivery.ps1 -TaskId task-1839566 -RepositoryId azure-planningspace-ps-excel-agent -PrepareOnly

# Native task-PR status sync (scheduled every 120 minutes; no AI for polling)
.\scripts\Sync-ActiveTaskPullRequests.ps1

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
- The configured reviewed-branch delivery capability is standing authorization for a normal `origin/<working-branch>` push only after a clean review and a passing independent verification bound to that exact review SHA, or after every independently confirmed remaining product finding is explicitly rejected or bypassed into an exact-review-bound open task-local debt item. It rejects stale/failed verification, blocked coverage, `main`/`master`, dirty worktrees, force, tags, approved/deferred/undecided confirmed findings, and untracked bypasses. Review-comment publication, deployments, and work-item mutation remain separately gated. Build queueing stays limited to `pipeline.repositories[].autoQueueDefinitionIds`; build 892 is allowed and deployment 891 is rejected.
- Pipeline responsibility is configuration-driven: `pipeline_monitor` observes every configured exact SHA; `developer` fixes supported product code/test/YAML failures; `reviewer` produces remediation review candidates and coverage; `review_verifier` independently verifies the exact review; `orchestrator` routes exceptions and validates completion; `health_check` owns ecosystem defects; `knowledge_keeper` publishes the final verified outcome.
- The configured Health verified-repair delivery capability is standing authorization only for the trusted host after full ecosystem validation. A dirty worktree is first captured in its entirety as a preservation commit, and the repair is committed separately on top. Delivery validates the exact ecosystem `origin` URL, avoids base-branch pushes, forbids force and tags, and verifies the exact final remote SHA. It does not authorize product repositories or any other external action.
- Host-compatible execution is the configured standing default for CLI, continuation, and Health runs. The dashboard still displays an explicit warning before its elevated start/recovery actions; neither path bypasses requirements holds, review decisions, credentials, or external-write gates.
- Every task/repository pair owns an isolated full clone and unique task branch. Exact run and lease IDs guard continuation and dashboard stop/resume actions, so a stale or failed task cannot mutate another task. The scheduler never executes in `repositories[].localWorkspace` and never uses worktrees, reset, clean, or Git stash for task switching.
