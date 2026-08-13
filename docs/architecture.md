# Architecture and responsibilities

The editable vector overview is available below and as a standalone file: [ecosystem-architecture.svg](assets/ecosystem-architecture.svg).

![Development Agent Ecosystem architecture](assets/ecosystem-architecture.svg)

## Repository composition

The repository-level diagram shows how source-controlled configuration, prompts, skills, scripts, generated agents, runtime state, and external services interact: [repository-architecture.svg](assets/repository-architecture.svg).

![Development Agent Ecosystem repository architecture](assets/repository-architecture.svg)

| Repository area | Role in the system |
|---|---|
| `config/agents.json` | Canonical agents, repositories, workspaces, credential strategy, modes, health policy, knowledge paths, and approval gates |
| `prompts/common` | Evidence, task-protocol, and approval rules shared across roles |
| `prompts/roles` | Role-specific behavior for Orchestrator, Keeper, Analyst, Developer, Reviewer, Pipeline Monitor, and Health Check Agent |
| `plugins/development-agent-ecosystem/skills` | Workflow and health-diagnostics skills plus vendored Azure PR and pipeline monitors |
| `scripts/AgentEcosystem.psm1` | JSON loading, semantic validation, path expansion, and TOML generation primitives |
| `scripts/Start-DevelopmentWorkflow.ps1` | Fresh-config startup, multi-repository workspace selection, task creation/resume, knowledge import, and Orchestrator launch |
| `scripts/Set-WorkflowInputRoute.ps1` | Idempotent task/comment routing into addressable agent inputs backed by `workflow-routing.jsonl` |
| `scripts/Request-OrchestratorCommentRouting.ps1` | Durable, idempotent return of out-of-scope targeted comments to Orchestrator with original-event traceability |
| `scripts/Switch-TaskWorkspace.ps1` | Single-task workspace lease, task-specific branch capture, tracked/untracked stash, and safe restore |
| `scripts/Start-NextQueuedTask.ps1` | Oldest-first continuation after the active task becomes idle; never launches concurrent task work |
| `scripts/Continue-AgentChain.ps1` | Event-driven next-link selection after successful targeted execution; uses a per-task exclusive lock, prioritizes authority handoffs to Orchestrator, normalizes repository scope, and preserves human, review, delivery, and failure gates |
| `scripts/Repair-AgentContinuations.ps1` | Deterministic reconciliation of durable successful outcomes whose trusted host exited before dispatch; never bypasses human gates and never duplicates a live continuation |
| `scripts/Invoke-ReviewedBranchDelivery.ps1` | Clean-review, clean-worktree, non-base, non-force branch push followed by exact-SHA monitoring |
| `scripts/Invoke-PostPushPipeline.ps1` | Exact pushed-ref verification, allowlisted build queueing, native run monitoring, result publication, and bounded Developer remediation routing |
| `scripts/Sync-TaskPullRequestStatus.ps1` | One-shot task-branch PR correlation; completed PR triggers final Keeper work, abandoned PR opens a question |
| `scripts/Sync-ActiveTaskPullRequests.ps1` | Shared model-free PR lifecycle index on a configurable schedule (120 minutes by default) |
| `scripts/Invoke-GuardedCodex.ps1` | Native Codex supervision, UTF-8 log normalization, three-identical-failure cutoff, and execution-guard artifacts |
| `scripts/Invoke-EcosystemHealthCheck.ps1` | Deterministic diagnostics, safe derived-state repairs, and OS-policy compatibility profile generation |
| `scripts/Start-AgentHealthRecovery.ps1` | One-attempt, ecosystem-only automatic source recovery using a bounded recent-log diagnostic bundle |
| `scripts/Save-AgentCheckpoint.ps1` | Private per-role context for running, waiting, or failed attempts; not shared with Knowledge Keeper |
| `scripts/Publish-AgentOutcome.ps1` | Validates configured artifacts, completes the role, and only then publishes its shared outcome |
| `scripts/Invoke-EnhancedReview.ps1` | Per-PR comment fingerprints, pending AI-processing state, and targeted Review Monitor invocation |
| `dashboard` | Full-width loopback UI with local diff review, external PR reports, persisted statuses, live logs, interventions, manual closure, revision reopen, and tracked elevated runspaces |
| `knowledge/managed` | Versioned managed knowledge with seed-import provenance |
| `%LOCALAPPDATA%/Codex/development-agent-ecosystem` | Mutable task ledgers, review prompts, notes, reports, and scheduler backups |

### Extension points shown on the diagram

Dashed green `+` badges identify supported extension points:

| Badge | How to extend it |
|---|---|
| `+ REPOSITORIES` | Add an enabled object to `repositories[]`; the dashboard and Review Monitor pick it up on their next start |
| `+ PROMPT PATHS` | Add a Markdown file and reference it from the target agent's `promptPaths[]` |
| `+ SKILL.MD` | Add a plugin skill directory containing `SKILL.md` and `agents/openai.yaml`, then reference it from `skillPaths[]` |
| `+ KNOWLEDGE ROOT` | Add a seed source, managed component knowledge, or a verified decision root under `knowledge` |
| `+ UI / DOCS` | Add maintained operator guidance or dashboard assets without changing agent contracts |
| `+ VALIDATORS` | Extend semantic checks in `AgentEcosystem.psm1` and the corresponding JSON schema together |
| `+ COMPILE STEPS` | Extend agent TOML generation while keeping `config/agents.json` canonical |
| `+ WORKFLOWS` | Add a guarded runtime script and expose its responsibility through Orchestrator or the dashboard |
| `+ REVIEW INPUTS` | Add a trusted adapter that normalizes evidence before it enters the untrusted review context |
| `+ UI ROUTES` | Add a loopback API route with session-token validation and a matching dashboard control |
| `+ AGENT ROLE` | Add an agent object, role prompt, skills, handoffs, required artifacts, and schema coverage |
| `+ ARTIFACT SCHEMA` | Add a versioned JSON schema and include the artifact in the producer and consumer contracts |
| `+ AUTH` | Add a credential profile that references a CLI or environment-variable name, never a plaintext secret |

## Component interaction

Agent progression is host-driven and event-based: Orchestrator classifies task intake and general comments from the current JSON responsibility directory, then every successful initial, resume, or targeted run returns to the trusted host, which starts the next eligible role directly. Successful publication first appends a durable `continuation-requested` event. If the host exits before the next dispatch, a local non-AI reconciler resumes only the missing transition after the configured grace period; a global recovery lock and per-task chain lock make this idempotent. Roles never poll one another or remain alive to wait for the next role. Developer completion may cross `review_pending` only to start Reviewer; a machine-readable Pipeline remediation may cross its waiting gate only to start Developer. All other human-input and approval gates stop the chain. A per-run bound allows at most sixteen handoffs and at most three repetitions of one role-to-role transition; exceeding either bound persists a failure and hands it to Health Check. A global workspace coordinator grants one task at a time ownership of all selected repositories; other tasks are durable queued work, not concurrent processes. Failed execution and explicit source-controlled ecosystem maintenance are handed to Health Check; its bounded `ecosystem_recovery` coordinator may change only the ecosystem repository, validates the result, and gets one affected-agent-only retry. Product code remains Developer-owned. Review Monitor owns authored/assigned PR discovery and the shared status index, while Pipeline Monitor owns exact task-branch correlation, build/remediation, and the completion gate.

Routing and knowledge are separate. Orchestrator owns task/comment classification and dispatch but performs no delivery work. Persisting a route appends an addressable input and never rewrites the selected agent's existing status. When new input changes work owned by a completed, waiting, interrupted, or failed role, Orchestrator may request its targeted restart; only trusted host continuation starts it after Orchestrator succeeds. A completed-PR signal follows `Pipeline Monitor -> Orchestrator -> Knowledge Keeper`: Orchestrator verifies the persisted terminal gate and routes one final-publication command. Knowledge Keeper issues a minimal context on request and answers explicit knowledge or skill requests throughout delivery; it never loops over `wait` or polls role logs. Each role autonomously sizes coherent work blocks and reads only direct or Orchestrator-routed comments once per checkpoint. Working details remain private until the role succeeds. Only a validated terminal outcome enters shared context, where Knowledge Keeper decides whether it changes task decisions, coding rules, or managed knowledge. After all applicable roles complete, it writes `task-summary.json`.

```mermaid
flowchart LR
    U[Developer / Dashboard] -->|new task + general comments| O[Workflow Orchestrator]
    U -->|explicit target or linked answer| T[Selected agent]
    O -->|routing question + waiting status| U
    O --> W{Single workspace lease}
    W -->|active task| GW[(Task branches + working trees)]
    W -->|busy| Q[(Oldest-first task queue)]
    GW -->|switch: stash tracked + untracked| Q
    Q -->|idle lease: branch + stash restore| W
    A[Azure Boards + comments] --> O
    O --> RA[Requirements Analyst]
    O --> K[Knowledge Keeper]
    C[Codebase] --> RA
    KB[(Versioned Knowledge)] <--> K
    S[(Engineering skills: common + stack-specific)] --> K
    K -->|initial minimal context| RA
    RA -->|knowledge / skill request| K
    K -->|bounded answer| RA
    RA -->|successful validated outcome only| K
    O --> D[Developer]
    K -->|context pack + selected engineering skills| D
    RA --> D
    D -->|plan, code, tests, evidence| K
    O --> R[Reviewer]
    K --> R
    K -->|same selected engineering skills| R
    RA --> R
    PR[Active PR code + user comments + local notes] --> R
    R -->|findings| K
    R -->|findings, no automatic fix| D
    U -->|approve / reject / defer / bypass| G{Review decision gate}
    G -->|approved findings only| D
    G -->|bypass + linked open debt| TD[(Task tech-debt items)]
    TD --> P
    O --> P[Azure Pipeline Monitor]
    P -->|clean review: guarded working-branch push| AZP[Azure Pipelines]
    AZP -->|exact SHA result| P
    RM[Review Monitor: authored + assigned PRs] --> IDX[(Shared PR status index)]
    IDX -->|active / completed / abandoned| P
    P -->|exact commit status + bounded failed logs| K
    P -->|completed PR closure evidence| O
    O -->|validated final-publication command| K
    P -->|code/test only; max 3 cycles| D
    O -->|failure or ecosystem maintenance request| H[Health Check Agent]
    X[Guarded runner: stop after 3 identical failures] -->|guard + failure artifacts| O
    H -->|diagnosis, verified maintenance + recovery status| O
    H -->|non-ecosystem correction only| D
    H -->|bounded ecosystem repair + one affected-agent restart| ES[(Ecosystem runtime)]
    K --> KB
```

## Task lifecycle

```mermaid
sequenceDiagram
    participant U as Developer
    participant O as Workflow Orchestrator
    participant W as Workspace Coordinator
    participant K as Knowledge Keeper
    participant A as Requirements Analyst
    participant D as Developer Agent
    participant R as Reviewer Agent
    participant P as Pipeline Monitor
    participant H as Health Check Agent
    participant G as Execution Guard

    U->>O: task ID / URL / selected repositories / instruction
    O->>W: request exclusive task workspace lease
    alt another task is running
        W-->>O: queued; do not start agents
    else workspace is available
        W->>W: stash previous task, switch branches, restore this task
        W-->>O: active lease
    end
    O->>O: classify task against current responsibilities
    O->>A: routed task intake
    A->>K: bounded knowledge / skill request
    K-->>A: verified context pack
    A-->>O: ready scope, held scope, questions, sources
    alt independent ready scope exists
        O->>D: approved implementation context
        D-->>K: successful implementation outcome
        D-->>O: completed status and artifact references
        O->>R: requirements + held scope + implementation
        R-->>K: successful review outcome
        R-->>O: findings and verdict
        R-->>D: findings for visibility
        U->>O: approve / reject / defer / bypass finding
        O->>D: approved findings only
        O->>R: materialize bypassed finding as task-local debt
        R-->>P: rejected or tracked-bypass review gate
        D->>P: pushed branch and exact commit
        P-->>K: successful exact-SHA outcome for shared knowledge
        P-->>O: delivery status
        alt code or test failure and cycle remains
            P-->>O: pipeline-remediation-request
            O->>D: only the failed code/test scope
            D->>R: locally verified remediation
            R-->>O: remediation review
            U->>D: authorize next push
            D->>P: new pushed SHA + remediation cycle
        else infrastructure / unknown / no run / limit reached
            P-->>O: terminal evidence for Health or operator gate
        end
        P-->>O: completed PR closure evidence
        O->>K: validated final-publication command
        K->>K: publish verified knowledge and task history
    else an agent or workflow fails
        G->>G: count normalized identical failures
        G-->>O: third failure + persisted guard artifact
        O->>H: failure signature + bounded recent tails
        H-->>O: diagnosis and deterministic repair result
        O->>H: one bounded ecosystem-only recovery attempt
        H-->>O: repaired / waiting / failed + validation
        O-->>U: live recovery status and Resume action
    else all scope is blocked by unanswered questions
        A-->>U: question-opened + waiting status + explicit hold
        U->>A: linked answer
        U->>O: general corrective command
        O->>A: routed correction
    end
```

## Per-task artifacts

Runtime task history is stored outside the repository under `%LOCALAPPDATA%/Codex/development-agent-ecosystem/tasks/<task-id>`:

- `task.json`: task identity, ordered `repositoryIds[]`, backward-compatible primary `repositoryId`, and current state;
- `task-ledger.jsonl`: append-only communication, workflow and agent status, `question-opened` / `question-resolved`, and user intervention comments;
- `workflow-routing.jsonl`: idempotent Orchestrator decisions linking each task/comment input to one or more agent owners;
- `workspace-session.json`: this task's branch and task-specific stash metadata for every selected repository;
- `agent-activity.jsonl`: append-only factual per-agent progress used by the configurable live dashboard view;
- `resume-plan.json`: the checkpoint snapshot listing only agents permitted to run and completed agents that must be preserved;
- `resume-artifact-index.json`: per-agent SHA-256 fingerprint baselines used to identify changed artifacts without model rereads or cross-role consumption;
- `agent-checkpoints/<agent-id>.json`: private unfinished-role context, never consumed by Knowledge Keeper or the dashboard outcome viewer;
- `context-pack.json`: context selected by Knowledge Keeper;
- `requirements-analysis.json`: ready scope, held scope, gaps, and questions;
- `implementation-plan.json` and `implementation-result.json`;
- `review-result.json`, `review-decisions.json`, and `tech-debt-items.json`; a `bypassed` decision is non-resolution and is deliverable only while its linked `TD-REV-NNN` item is open;
- `delivery-result.json`, `pipeline-result.json`, `pull-request-status.json`, optional `pipeline-remediation-<signature>.json`, `knowledge-update.json`, and final `task-summary.json`;
- `task-closure.json` plus `revisions/revision-<n>/` snapshots for manual closure and bug/rework reopen.
- `agent-failure-*.json`, `health-check-result.json`, `health-recovery-result.json`, and health recovery logs.
- `health-repair-routing.json` records a bounded, single-owner correction handoff when Health Check cannot perform the repair inside the ecosystem recovery workspace.

The global `%LOCALAPPDATA%/Codex/development-agent-ecosystem/workspace-coordinator.json` records the one task that currently owns shared product workspaces. Its lock file serializes native scheduler decisions. Task stashes remain ordinary Git stash commits until successfully applied; no scheduler path uses reset, clean, force checkout, or pop.

`task.json` is a current-state projection used for fast dashboard rendering. `task-ledger.jsonl` remains the durable public history. Open questions are reconstructed by subtracting every `question-resolved` evidence reference from `question-opened` events; a targeted dashboard answer closes only its selected question. Applicable comments are coalesced at end-of-block checkpoints, so saving comments does not restart a running role. Agents do not poll while a block is running and perform a final comment check before outcome publication. General resume computes a checkpoint and dispatches only unfinished roles; explicit targeted restart dispatches exactly one stopped or completed role. Per-agent baselines in `resume-artifact-index.json` let each role reuse summaries for artifacts it previously consumed without allowing another role to advance its baseline. Only the resume plan supplied to an agent advances that agent's baseline; post-outcome bookkeeping preserves every baseline so the next chained role receives every hash-divergent artifact as changed. The dashboard polling itself is deterministic and does not invoke a model. Health recovery receives configured tails rather than complete historical logs. PR comment fingerprints are stored per PR; only that PR is forced, while `pending-review-changes.json` records `pending-ai-review` or `requires-human-intervention` until AI processing succeeds. Pipeline Monitor uses low reasoning effort and lets its native monitor perform repeated status polling without repeated model turns. Post-push classification is also deterministic: only code/test failures create a deduplicated Developer request, while infrastructure/no-run/unknown states remain at their proper gate and the cycle stops after three attempts.

Every context pack has an `engineeringGuidance` section. Knowledge Keeper derives the stack from repository evidence, always selects pragmatic DRY, KISS, SOLID, YAGNI, separation-of-concerns, testability, and maintainability guidance, and adds only the applicable .NET, JavaScript/TypeScript, and React skills. Developer implements against that selection; Reviewer uses the same selection and reports a principle violation only when it has a concrete correctness, maintenance, or testing consequence.

Schemas are stored under `config/schemas`. Knowledge Keeper may publish only evidence-backed claims with all required evidence fields.
