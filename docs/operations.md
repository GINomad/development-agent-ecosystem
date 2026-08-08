# Operations and rollback

## Daily use

Start the main dashboard:

```powershell
.\scripts\Start-AgentDashboard.ps1
```

From the dashboard:

- select one or more repositories; the first checked repository is the primary workspace and the rest are additional writable workspaces for that task;
- select manual or automate mode;
- in manual mode, enter a task ID or URL, or select a task from the assigned-task inbox;
- add an optional instruction for the current run;
- track active or completed tasks, every agent status, generated artifacts, and the append-only event timeline;
- use **View outcome** on an agent card to inspect that role's configured required artifacts and exact persisted status without inferring a result from live logs;
- click an agent card to open its persistent live activity log; it refreshes every `ui.agentLogRefreshSeconds` (30 seconds by default);
- write a comment directly to the selected agent, or use **Restart agent with comment** to save the comment and start only that agent through Knowledge Keeper;
- use **Stop workflow** to stop only the selected task's validated process tree or tracked runspace while preserving task history, completed agents, and artifacts;
- select any supported text artifact to preview JSON, JSONL, Markdown, text, logs, TOML, YAML, XML, HTML source, or CSV in the read-only viewer (limited to 1 MiB);
- inspect the yellow **Input required** panel whenever any agent is waiting for information;
- choose **Answer this question**, enter the answer or corrective command, and send it; the answer is linked to that exact question in the append-only ledger;
- add a general task comment to clarify requirements, pause scope, or redirect the next in-scope step without falsely resolving a question;
- resume an existing task without creating a duplicate history directory;
- after an OS sandbox failure, select **Resume workflow elevated** and confirm one task-specific elevated session;
- attach a Reviewer note to a repository, PR, or task;
- select **Run review** to read active PR code, user comments, and local notes.

The task action guide is also displayed directly below the buttons:

- **Send comment** appends an operator instruction to the task ledger. A running agent finishes its current coherent work block, reads all applicable comments once, processes them as one ordered batch, and decides its next block without restart. When a Reply target is selected, the action also resolves that exact question. A stopped workflow remains stopped until Resume.
- **Resume workflow** computes `resume-plan.json` and continues only unfinished agents in the normal Codex sandbox; completed agents and their artifacts are not rerun.
- **Resume workflow elevated** applies the same checkpoint plan without the Codex OS sandbox for one confirmed session; all delivery gates remain active.
- **Restart agent with comment** saves an addressable `targetAgentId` comment and starts only the selected agent in the default elevated mode used on this machine.
- **Stop workflow** marks running agents `waiting` and the task `interrupted` after stopping its validated process tree or tracked in-process runspace.
- **Approve elevated repair** gives Health Check one elevated ecosystem-repair attempt; it neither resumes implementation nor authorizes product-code changes.

The task monitor refreshes every five seconds and reconstructs its state from `%LOCALAPPDATA%\Codex\development-agent-ecosystem\tasks`, so page reloads and dashboard restarts do not erase status. Dashboard and live-log polling are ordinary local HTTP/file reads and consume no AI tokens. A selected agent log refreshes every `ui.agentLogRefreshSeconds` (30 seconds by default). Each running role chooses the largest coherent block allowed by ready scope, dependencies, reversibility, validation cost, approval gates, and context limits. At block completion it uses `Get-AgentCommentBatch.ps1` once and acknowledges the processed IDs with `Acknowledge-AgentCommentBatch.ps1`. It never idle-polls for comments. Any role that needs information calls `Open-AgentQuestion.ps1`; this records the minimal public question while detailed unfinished context stays in `agent-checkpoints/<agent-id>.json`. Knowledge Keeper remains pull-based and `Publish-AgentOutcome.ps1` performs one final comment checkpoint before sharing a terminal outcome.

## Automatic agent health recovery

Every failed agent handoff includes a structured failure artifact with the agent, stage, exit code, diagnostic, evidence paths, and stable failure signature. Knowledge Keeper immediately starts Health Check Agent; a root workflow crash uses the same path from the host wrapper.

`Invoke-GuardedCodex.ps1` supervises the workflow and Health recovery runners. The same normalized failure signature may occur at most three times in one run. Waiting, changing shells, or re-emitting the same native-process error does not reset the counter. At the third occurrence the supervisor terminates the child process, marks the task failed, persists the execution-guard and agent-failure artifacts, and routes those artifacts to Health Check Agent. This prevents an agent from entering an execution or wait loop.

When the evidence contains `CreateProcessWithLogonW 1260`, Health Check automatically recompiles all six roles as suffixed host-compatible agents. Each derived definition keeps its normal prompts and skills, adds the OS-policy compatibility rules, and changes only the Codex sandbox mode. Health Check marks the task `interrupted` at `os_policy_compatibility_ready`; it does not launch the profiles or repeat sandbox recovery. Confirm **Resume workflow elevated** to select them. The dashboard starts this workflow in a tracked in-process runspace rather than a nested `powershell.exe -EncodedCommand`, then Codex launches directly. This changes Codex process isolation, not CrowdStrike, AppLocker, WDAC, repository permissions, or approval gates.

Health recovery runs in three bounded phases:

1. deterministic checks and safe repairs through `Invoke-EcosystemHealthCheck.ps1`;
2. read-only diagnosis by `development_health_check`;
3. an ecosystem-only recovery coordinator when source repair is supported by evidence.

The recovery coordinator cannot access product repositories or perform external writes. It does not commit or push. It receives `health-diagnostic-context.json`, containing only the configured workflow-log, ledger, and final-response tails. It runs once per failure signature, validates the exact repair plus `Test-AgentEcosystem.ps1`, and exposes its `running`, `waiting`, `completed`, or `failed` state on the task dashboard. A successful recovery changes the task to `interrupted`, ready for an explicit **Resume workflow**.

If the sandboxed agent is blocked by Windows process-creation error 1260, select **Approve elevated repair** on the task card and confirm the warning. This authorizes one `danger-full-access` retry for that task and failure signature. The launcher still requires a clean ecosystem worktree, starts in the exact ecosystem root without additional writable directories, and keeps product/external writes disabled. The OS does not enforce the repository boundary during that single elevated attempt.

If the normal development workflow itself is blocked by the OS, select **Resume workflow elevated** and confirm the warning. All agent roles in that resumed orchestration inherit the elevated outer Codex session, but they cannot disable the execution guard or bypass held scope, human review decisions, Git push, PR publication, pipeline queueing, or work-item mutation gates. Use this action only for the affected task.

Manual health check:

```powershell
.\scripts\Invoke-EcosystemHealthCheck.ps1 -TaskId task-1854726 -Repair
```

## Review approval gate

Reviewer records findings but does not authorize changes. Record the human decision separately:

```powershell
.\scripts\Set-ReviewDecision.ps1 -TaskId task-1839566 -FindingId R-001 -Decision approved -Reason 'Fix before merge'
```

Allowed decisions are `approved`, `rejected`, and `deferred`. Developer must not apply a finding without an `approved` decision.

## Scheduled tasks

- `Development Ecosystem - PR Review Updates`: polls active assigned PRs;
- `Development Ecosystem - PR Review Daily`: performs the complete daily pass;
- `Development Ecosystem - PR Review Dashboard`: starts the loopback report server at logon.

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
