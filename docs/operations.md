# Operations and rollback

## Daily use

Start the main dashboard:

```powershell
.\scripts\Start-AgentDashboard.ps1
```

From the dashboard:

- switch between **Local Developer review** (PR-style task diff and line-aware local comments) and **External PR reviews** (a compact list of active authored or assigned PRs with Azure links and direct links to the Review Monitor HTML UI);
- use **Close task and update knowledge** with a reason to stop delivery and run only the final Knowledge Keeper scope;
- select a completed task under **All** and use **Reopen as new revision** to archive the previous revision and continue from Requirements Analyst or Developer;
- select one or more repositories; the scheduler creates or resumes a full task-specific clone for each selection, using the first clone as the primary workspace and the rest as additional writable workspaces;
- select manual or automate mode;
- in manual mode, enter a task ID or URL, or select a task from the assigned-task inbox;
- add an optional instruction for the current run;
- track scheduler capacity, active leases, FIFO queue positions, clone path/branch/base SHA, active or completed tasks, every agent status, generated artifacts, and the append-only event timeline;
- treat `queued` as a durable capacity wait, not a failed start; the oldest queued task starts when any configured task slot is released;
- use **View outcome** on an agent card to inspect that role's configured required artifacts and exact persisted status without inferring a result from live logs;
- click an agent card to open its persistent live activity log; it refreshes every `ui.agentLogRefreshSeconds` (30 seconds by default) and shows the material operation, target, evidence-based progress, bounded evidence, and next action when the agent supplied them;
- write a comment directly to the selected agent; if its content exceeds that role's configured authority, the agent returns it to Orchestrator and the trusted host automatically runs the rerouting chain after the current successful block;
- use **Stop workflow** to stop only the selected task's validated process tree or tracked runspace while preserving task history, completed agents, and artifacts;
- select any supported text artifact to preview JSON, JSONL, Markdown, text, logs, TOML, YAML, XML, HTML source, or CSV in the read-only viewer (limited to 1 MiB);
- inspect the yellow **Input required** panel whenever any agent is waiting for information;
- choose **Answer this question**, enter the answer or corrective command, and send it; the answer is linked to that exact question in the append-only ledger;
- add a general task comment for Orchestrator to classify and route to the smallest sufficient agent set without falsely resolving a question;
- resume an existing task without creating a duplicate history directory;
- use **Resume workflow elevated** to force the host-compatible profile for an existing interrupted task; the standing configuration already selects this profile for ordinary starts and continuations;
- attach a Reviewer note to a repository, PR, or task;
- select **Run review** to read active PR code, user comments, and local notes.

The task action guide is also displayed directly below the buttons:

- **Send comment** appends an operator instruction to the task ledger. A general comment is queued for Orchestrator classification; a selected agent or question target remains direct. At the next checkpoint Orchestrator writes an idempotent route, and the selected agent reads the routed batch after its current coherent block. A stopped workflow remains stopped until Resume.
- **Resume workflow** computes `resume-plan.json` and continues only unfinished agents with the configured execution profile; the current standing policy resolves it to the host-compatible profile, and completed agents and their artifacts are not rerun.
- **Resume workflow elevated** explicitly applies the same checkpoint plan without the Codex OS sandbox; all delivery gates remain active.
- **Restart agent with comment** saves an addressable `targetAgentId` comment and schedules only the selected agent in the default elevated mode used on this machine. If scheduler capacity is full, this task remains `queued` in FIFO order and starts when a slot is released.
- **Stop workflow** marks running agents `waiting` and the task `interrupted` after stopping its validated process tree or tracked in-process runspace.
- **Approve elevated repair** gives Health Check one elevated ecosystem-repair attempt; it neither resumes implementation nor authorizes product-code changes.

The task monitor refreshes every five seconds and reconstructs its state from `%LOCALAPPDATA%\Codex\development-agent-ecosystem\tasks`, so page reloads and dashboard restarts do not erase status. Dashboard and live-log polling are ordinary local HTTP/file reads and consume no AI tokens. A selected agent log refreshes every `ui.agentLogRefreshSeconds` (30 seconds by default). Orchestrator handles new intake, general comments, and durable authority handoffs in one batch per checkpoint and never idle-polls. Each delivery role similarly reads only its direct and routed comment batch; `Request-OrchestratorCommentRouting.ps1` atomically forwards and acknowledges comments outside that role's JSON responsibilities. The successful role handoff automatically prioritizes Orchestrator, so no operator restart is required. Any role that needs information calls `Open-AgentQuestion.ps1`; detailed unfinished context stays in `agent-checkpoints/<agent-id>.json`. Knowledge Keeper remains pull-based and consumes only successful outcomes.

Dashboard workflow and review actions run as tracked in-process PowerShell runspaces. They do not spawn nested `powershell.exe -EncodedCommand` children, so host security products can evaluate the stable dashboard process instead of blocking an encoded bootstrap before `task.json` and the Health Check failure envelope exist. The standing runtime policy resolves starts to the host-compatible profile; the dashboard also presents a warning before its elevated start control. Neither mechanism disables CrowdStrike or bypasses delivery gates.

Task execution is capacity-limited rather than globally serialized. `workspace-coordinator.json` records up to `maxActiveTasks` exact task/run/lease records and admits overflow work by creation time and task ID. Each `(taskId, repositoryId)` runs only in its full clone under `workspaceRoot/task-<task-key>/repo-<repository-key>`; `tasks/<task-id>/workspaces/<repository-id>.json` records the canonical origin, base SHA, unique branch, lifecycle, run ID, and lease ID. One controller/agent chain may run per task. Stop, failure, and completion release only that task lease, retain its clone and uncommitted work for resume, and then admit the oldest queued task. A live runner refreshes its exact lease heartbeat; the next admission recovers terminal leases or any exact heartbeat expired beyond the configured grace, uses PID/start identity to classify an exited host versus a dead in-process runspace, marks a non-terminal orphan `interrupted`, and retains its clone. Exact run/lease/revision checks reject stale dashboard actions. The scheduler never executes in `repositories[].localWorkspace`, shares a clone, uses worktrees or stashes, or resets/cleans another task's work.

Every human-input gate is self-explanatory: it records the requested action, why automation cannot continue safely, concrete options, one recommended option, and the rationale for preferring it. The dashboard receives the same structured guidance as the durable task ledger.

## Post-push pipeline and Developer remediation

The canonical owners and current definition IDs are listed in [pipeline monitoring and ownership](pipeline-monitoring.md). In short, Pipeline Monitor owns all configured exact-SHA observation; Developer and Reviewer own the bounded product remediation loop; Orchestrator owns exceptional and terminal routing; Health Check owns ecosystem defects; Knowledge Keeper owns final publication.

After an authorized push succeeds, Developer passes the exact repository ID, branch, full pushed SHA, and the UTC timestamp recorded immediately before the push to Pipeline Monitor. `Invoke-PostPushPipeline.ps1` verifies that the local `origin/<branch>` tracking ref equals that SHA, then runs the native watcher once. The watcher performs its own deterministic polling, so no model turn is spent on every status refresh.

The watcher discovers only runs whose full `sourceVersion` equals the pushed SHA. If canonical JSON contains an ordered approved build sequence, it queues each definition only after the previous definition succeeds. For `ps-excel-agent`, the standing sequence is 814 then a new 892; an earlier 892 is ignored for acceptance. Deployment 891 is never auto-queued; `ps-bicep` and `ps-app-delfi` currently have empty auto-queue lists.

Failed task logs are reduced to the configured tail and byte limit, then classified without an AI call:

- `code` and `test`: write a deduplicated `pipeline-remediation-<signature>.json`, set Developer, Reviewer, and Pipeline Monitor back to `pending`, and append a targeted `pipeline-remediation-request`; this preserves prior artifacts while ensuring the new commit is reviewed and monitored;
- `infrastructure`, credentials, `unknown`, or `no-run`: keep the result visible for Knowledge Keeper, Health Check, or operator action; do not ask Developer to guess;
- after three remediation cycles: write `limit-reached` and stop the loop.

Developer fixes only supported code/test evidence, runs local validation, and sends the change through Reviewer. A later push still requires explicit authorization. After that push, Pipeline Monitor validates the new exact SHA; completed unrelated agents and artifacts are not restarted.

Manual invocation after a successful push:

```powershell
.\scripts\Invoke-PostPushPipeline.ps1 `
  -TaskId task-1839566 `
  -RepositoryId azure-planningspace-ps-excel-agent `
  -PushWasSuccessful `
  -Branch feature/example `
  -Commit 0123456789abcdef0123456789abcdef01234567 `
  -QueuedAfter '2026-08-08T12:00:00Z'
```

## Automatic agent health recovery

The scheduled task **Development Ecosystem - Task PR Lifecycle** runs every `pipeline.pullRequests.pollIntervalMinutes` (120 minutes by default). It performs Azure PR status reads without a model. When a matching manually created PR becomes completed, it sends the terminal evidence to Orchestrator; Orchestrator then routes the final update to Knowledge Keeper. Run `Sync-ActiveTaskPullRequests.ps1` for an immediate operator-triggered sync.

The scheduled task **Development Ecosystem - Continuation Recovery** starts one hidden resident PowerShell host at logon instead of creating a new console process every interval. The host reloads configuration and reads only local task state every `workflow.automaticContinuation.recoveryPollIntervalMinutes` (one minute by default). When a successful outcome has no live owner and no completed downstream dispatch after `recoveryGraceSeconds`, it resumes exactly the missing next role. Existing human gates, a live host, or a completed downstream outcome are recorded as reconciled and never restarted. This polling uses no AI tokens; tokens are consumed only when recovery actually launches a role.

Every failed agent handoff includes a structured failure artifact with the agent, stage, exit code, diagnostic, evidence paths, and stable failure signature. Orchestrator hands that bounded failure envelope to Health Check Agent; a root workflow crash uses the same path from the host wrapper.

`Invoke-GuardedCodex.ps1` supervises the workflow and Health recovery runners. The same normalized failure signature may occur at most three times in one run. Waiting, changing shells, or re-emitting the same native-process error does not reset the counter. At the third occurrence the supervisor terminates the child process, marks the task failed, persists the execution-guard and agent-failure artifacts, and routes those artifacts to Health Check Agent. This prevents an agent from entering an execution or wait loop.

When the evidence contains `CreateProcessWithLogonW 1260`, Health Check verifies or recompiles all seven suffixed host-compatible agents. Each derived definition keeps its normal prompts and skills, adds the OS-policy compatibility rules, and changes only the Codex sandbox mode. Health Check marks the task `interrupted` at `os_policy_compatibility_ready`; the standing policy selects the compatible profile on the next targeted resume, while the explicit **Resume workflow elevated** action remains available in the dashboard. The dashboard starts this workflow in a tracked in-process runspace rather than a nested `powershell.exe -EncodedCommand`, then Codex launches directly. This changes Codex process isolation, not CrowdStrike, AppLocker, WDAC, repository permissions, or approval gates.

Health recovery runs in three bounded phases:

1. deterministic checks and safe repairs through `Invoke-EcosystemHealthCheck.ps1`;
2. read-only diagnosis by `development_health_check`;
3. an ecosystem-only recovery coordinator when source repair is supported by evidence, or a bounded handoff to the configured agent that owns a non-ecosystem correction.

The recovery coordinator cannot access product repositories or perform external writes. It may edit the ecosystem repository and, after complete validation, the trusted host creates one commit containing only the verified repair. With `pushVerifiedRepairs=true`, the trusted host normally pushes that exact commit to the configured ecosystem `origin`: base branches are replaced by a deterministic repair branch, force and tags are forbidden, and `ls-remote` must confirm the exact SHA before recovery continues. The recovery model itself never commits or pushes. For a failure it receives `health-diagnostic-context.json`, containing only the configured workflow-log, ledger, and final-response tails. For an explicit ecosystem maintenance request it receives the routed request and relevant ecosystem files. Health Check owns changes to ecosystem scripts, JSON configuration and schemas, prompts, skills, dashboard, generated-agent contracts, tests, documentation and diagrams, scheduling, and control-plane behavior; Orchestrator routes that scope to Health Check instead of product Developer.

When a completed Health Check diagnosis already exists, the coordinator reuses it instead of spending another model pass on the same evidence. It runs once per failure signature or bounded maintenance request and validates the exact behavior plus `Test-AgentEcosystem.ps1`. A validated ecosystem repair automatically restarts only the affected agent once. A non-ecosystem correction is routed once to its owner: Orchestrator for routing decisions without source mutation, Developer for product code/tests/product pipeline YAML, Requirements Analyst for requirements evidence, Knowledge Keeper for persisted task knowledge, Reviewer for product review work, or Pipeline Monitor for provider-side diagnosis. Credentials, approvals, external authority, and ambiguous evidence stop at `waiting_for_input`.

Standing user policy selects the host-compatible `danger-full-access` profile for every workflow and Health recovery run to avoid Windows process-creation error 1260. Role, review, credential, and external-write gates still apply. Before Health repair, the trusted host commits every tracked and untracked non-ignored ecosystem change as a separate preservation commit, records `health-recovery-preservation.json`, and starts repair from that clean HEAD. After complete validation it commits any repair on top and may push the final chain under the exact-origin policy.

If an existing task still records an OS-policy interruption, use **Resume workflow elevated** for that affected task. All agent roles in the resumed orchestration inherit the host-compatible outer Codex session, but they cannot disable the execution guard or bypass held scope, human review decisions, Git push, PR publication, pipeline queueing, or work-item mutation gates.

Manual health check:

```powershell
.\scripts\Invoke-EcosystemHealthCheck.ps1 -TaskId task-1854726 -Repair
```

## Review approval gate

The local task review diff includes the complete persisted Reviewer summary, product findings, held-scope violations, agent-process suggestions, and requirement-to-code traceability. The code pane has its own vertical and horizontal scroll. Select a diff row to reveal the comment editor directly below that row; click the same selected row again to close it, or click another row to move it. No editor overlays an unselected file. Source-specific Reviewer findings are rendered inline at their structured `codeLocation`. Requirement Traceability records one entry per analyzed requirement and exposes exact repository-relative files and one-based line ranges; selecting a reference navigates to that diff line when it is part of the current patch. Each finding has a durable reply thread backed by `task-ledger.jsonl`. **Send to Reviewer** requests clarification or correction from Reviewer; **Send to Developer** queues the same item as implementation input. Neither action restarts an agent or approves a finding. Use the separate restart and review-decision controls when those actions are intended.

Reviewer records findings but does not authorize changes. Record the human decision separately:

```powershell
.\scripts\Set-ReviewDecision.ps1 -TaskId task-1839566 -FindingId REV-001 -Decision approved -DecidedBy user -Note 'Fix before merge'
```

Allowed decisions are `approved`, `rejected`, `deferred`, and `bypassed`. Developer must not apply a finding without an `approved` decision. `deferred` remains blocking. `bypassed` requires a non-empty reason and atomically creates or reuses `TD-REV-NNN` in task-local `tech-debt-items.json`; the finding remains unresolved but Pipeline Monitor may continue. A missing, closed, or mismatched debt item fails the delivery gate.

## Scheduled tasks

- `Development Ecosystem - PR Review Updates`: polls active assigned PRs;
- `Development Ecosystem - PR Review Daily`: performs the complete daily pass;
- `Development Ecosystem - PR Review Dashboard`: starts the loopback report server at logon;
- `Development Ecosystem - Task PR Lifecycle`: synchronizes task PR state every `pipeline.pullRequests.pollIntervalMinutes` without model polling;
- `Development Ecosystem - Continuation Recovery`: keeps one hidden resident host that reconciles missing durable continuations;
- `Development Ecosystem - Knowledge Weekly Report`: renders the configured weekly evidence report without invoking AI.

Review reports are local by default. The monitor writes Markdown and interactive HTML reports to `%LOCALAPPDATA%\Codex\development-agent-ecosystem\azure-pr-review-monitor\reports`; `latest-summary.md` points to the newest run state. Comment hashes are tracked per PR. A changed comment forces only that PR, and `pending-review-changes.json` keeps the change visible as `pending-ai-review` or `requires-human-intervention` until a successful review consumes it. Nothing is emailed or posted to Azure DevOps automatically; publishing a selected finding remains an explicit, approval-gated action.

## Rollback

```powershell
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Rollback
```

Rollback disables the new tasks and enables the legacy `Codex PR Review - ...` tasks. It does not remove the new plugin, its isolated `DataRoot`, or either global monitor skill, so diagnostics and forward migration remain available.

After the new ecosystem is stable, the global `azure-pr-review-monitor` and `azure-pipeline-monitor` copies may be removed manually as a separate decision. They are never deleted automatically.

## Diagnostics

```powershell
.\scripts\Test-AgentEcosystem.ps1
.\scripts\Invoke-EnhancedReview.ps1 -Mode Manual -DryRun
.\scripts\Sync-ReviewMonitorConfig.ps1
```

If the new review dry run fails, legacy scheduled tasks remain enabled. If installation fails after partially disabling legacy tasks, the installation script re-enables every legacy task it already disabled.
