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
- attach a Reviewer note to a repository, PR, or task;
- select **Run review** to read active PR code, user comments, and local notes.

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
