# Operations and rollback

## Daily use

Start the main dashboard:

```powershell
.\scripts\Start-AgentDashboard.ps1
```

From the dashboard:

- select manual or automate mode;
- in manual mode, enter a task ID or URL, or select a task from the assigned-task inbox;
- add an optional instruction for the current run;
- track active or completed tasks, every agent status, generated artifacts, and the append-only event timeline;
- select any supported text artifact to preview JSON, JSONL, Markdown, text, logs, TOML, YAML, XML, HTML source, or CSV in the read-only viewer (limited to 1 MiB);
- add a task comment to clarify requirements, answer an open question, pause scope, or redirect the next in-scope step;
- resume an existing task without creating a duplicate history directory;
- after an OS sandbox failure, select **Resume workflow elevated** and confirm one task-specific elevated session;
- attach a Reviewer note to a repository, PR, or task;
- select **Run review** to read active PR code, user comments, and local notes.

The task monitor refreshes every five seconds and reconstructs its state from `%LOCALAPPDATA%\Codex\development-agent-ecosystem\tasks`, so page reloads and dashboard restarts do not erase status. A running Knowledge Keeper reads new `user-comment` events before every agent handoff and after every agent result. A stopped workflow keeps the comment for the next **Resume workflow** action.

## Automatic agent health recovery

Every failed agent handoff includes a structured failure artifact with the agent, stage, exit code, diagnostic, evidence paths, and stable failure signature. Knowledge Keeper immediately starts Health Check Agent; a root workflow crash uses the same path from the host wrapper.

`Invoke-GuardedCodex.ps1` supervises the workflow and Health recovery runners. The same normalized failure signature may occur at most three times in one run. Waiting, changing shells, or re-emitting the same native-process error does not reset the counter. At the third occurrence the supervisor terminates the child process, marks the task failed, persists the execution-guard and agent-failure artifacts, and routes those artifacts to Health Check Agent. This prevents an agent from entering an execution or wait loop.

Health recovery runs in three bounded phases:

1. deterministic checks and safe repairs through `Invoke-EcosystemHealthCheck.ps1`;
2. read-only diagnosis by `development_health_check`;
3. an ecosystem-only recovery coordinator when source repair is supported by evidence.

The recovery coordinator cannot access product repositories or perform external writes. It does not commit or push. It runs once per failure signature, validates the exact repair plus `Test-AgentEcosystem.ps1`, and exposes its `running`, `waiting`, `completed`, or `failed` state on the task dashboard. A successful recovery changes the task to `interrupted`, ready for an explicit **Resume workflow**.

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

Review reports are local by default. The monitor writes Markdown and interactive HTML reports to `%LOCALAPPDATA%\Codex\development-agent-ecosystem\azure-pr-review-monitor\reports`; `latest-summary.md` points to the newest run state. The dashboard scheduled task serves that directory on loopback. Nothing is emailed or posted to Azure DevOps automatically; publishing a selected finding remains an explicit, approval-gated action.

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
