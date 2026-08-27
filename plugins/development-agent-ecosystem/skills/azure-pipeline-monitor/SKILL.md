---
name: azure-pipeline-monitor
description: Monitor Azure DevOps pipeline runs associated with an exact Git branch push or commit, optionally queue explicitly approved build-only definitions, wait for every matching build to finish, and extract failed task logs. Use after Codex runs git push, or when the user asks to check, watch, monitor, validate, or troubleshoot Azure pipelines/builds for a pushed branch or commit.
---

# Azure Pipeline Monitor

## Workflow

1. Record the UTC time immediately before `git push` when possible.
2. After a successful push, resolve the repository, branch, and full commit SHA with Git.
3. Read `references/planning-space.md` when working in `ps-excel-agent` or `ps-bicep`.
4. Run `scripts/watch_pipeline_runs.ps1` with the exact branch and commit. In `ps-excel-agent`, pass `-AutoQueueDefinitionIds 814,892`; the script requires exact-SHA 814 success before it queues and accepts the later 892 run. In the ecosystem, prefer `Invoke-PostPushPipeline.ps1`, which reads this ordered allowlist from canonical JSON.
5. Stay with every discovered run until it reaches a terminal state. If command execution yields a running cell or session, retain the handle and use the provided wait/resume mechanism until the same watcher command completes. Do not start another watcher or refresh while that handle is live; an `inProgress` result or execution yield is not a failure, and only terminal watcher completion or a real nonzero exit may drive result/failure handling.
6. Report run IDs, links, source commits, final results, and failed task log excerpts.
7. When `-ResultPath` is supplied, persist the structured exact-SHA result and deterministic failure classification. With `-PassThru`, return non-success as data so the orchestrator can route bounded code/test remediation without treating the monitor itself as crashed.
8. In the ecosystem, pass `-ProgressCallback` and the configured heartbeat interval so queue, discovery, waiting, failure-analysis, and terminal stages appear in the dashboard. The callback is native PowerShell reporting and must not invoke an AI model.
9. When Azure rejects an approved queue request before creating a run, let the watcher perform the built-in queue-validation diagnosis. It must retain the single queue attempt, use an exact-branch/exact-commit dry-run preview plus read-only definition, Environment, and service-connection checks, sanitize CLI output, and persist the result under `pipeline-result.json.queueFailure`. Never retry the queue merely to obtain debug output.

Example:

```powershell
& "$HOME/.codex/skills/azure-pipeline-monitor/scripts/watch_pipeline_runs.ps1" `
  -Branch (git branch --show-current) `
  -Commit (git rev-parse HEAD) `
  -QueuedAfter ((Get-Date).ToUniversalTime().AddMinutes(-5))
```

For `ps-excel-agent`, run the approved exact-SHA build sequence. An earlier 892 run cannot satisfy the second step:

```powershell
& "$HOME/.codex/skills/azure-pipeline-monitor/scripts/watch_pipeline_runs.ps1" `
  -Branch (git branch --show-current) `
  -Commit (git rev-parse HEAD) `
  -AutoQueueDefinitionIds 814,892
```

## Guardrails

- Match the full `sourceVersion`; branch-only matches can select unrelated pushes.
- Never report success when no matching run exists. Report that no pipeline was triggered.
- Auto-queue only definitions explicitly approved in the repository reference. For PlanningSpace `ps-excel-agent`, build definitions `814` then `892` are approved as an ordered sequence.
- Never queue deployment pipelines without explicit user authorization and required parameters.
- Do not expose access tokens, service-principal credentials, or masked log values.
- Treat `partiallySucceeded`, `failed`, `canceled`, and timed-out runs as non-success.
- If a run fails, retrieve the failed task timeline records and include the high-signal tail of each log.
- Route only deterministic code/test classifications to Developer. Infrastructure, credentials, unknown failures, and remediation-limit results require a different gate.
