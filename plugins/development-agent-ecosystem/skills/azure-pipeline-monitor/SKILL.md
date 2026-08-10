---
name: azure-pipeline-monitor
description: Monitor Azure DevOps pipeline runs associated with an exact Git branch push or commit, optionally queue explicitly approved build-only definitions, wait for every matching build to finish, and extract failed task logs. Use after Codex runs git push, or when the user asks to check, watch, monitor, validate, or troubleshoot Azure pipelines/builds for a pushed branch or commit.
---

# Azure Pipeline Monitor

## Workflow

1. Record the UTC time immediately before `git push` when possible.
2. After a successful push, resolve the repository, branch, and full commit SHA with Git.
3. Read `references/planning-space.md` when working in `ps-excel-agent` or `ps-bicep`.
4. Run `scripts/watch_pipeline_runs.ps1` with the exact branch and commit. In `ps-excel-agent`, pass `-AutoQueueDefinitionIds 892`; the script suppresses duplicate runs for the same SHA. In the ecosystem, prefer `Invoke-PostPushPipeline.ps1`, which reads this allowlist from canonical JSON.
5. Stay with every discovered run until it reaches a terminal state.
6. Report run IDs, links, source commits, final results, and failed task log excerpts.
7. When `-ResultPath` is supplied, persist the structured exact-SHA result and deterministic failure classification. With `-PassThru`, return non-success as data so the orchestrator can route bounded code/test remediation without treating the monitor itself as crashed.

Example:

```powershell
& "$HOME/.codex/skills/azure-pipeline-monitor/scripts/watch_pipeline_runs.ps1" `
  -Branch (git branch --show-current) `
  -Commit (git rev-parse HEAD) `
  -QueuedAfter ((Get-Date).ToUniversalTime().AddMinutes(-5))
```

For `ps-excel-agent`, automatically queue Docker build `892` when no matching run exists, while still discovering other runs for the same commit:

```powershell
& "$HOME/.codex/skills/azure-pipeline-monitor/scripts/watch_pipeline_runs.ps1" `
  -Branch (git branch --show-current) `
  -Commit (git rev-parse HEAD) `
  -AutoQueueDefinitionIds 892
```

## Guardrails

- Match the full `sourceVersion`; branch-only matches can select unrelated pushes.
- Never report success when no matching run exists. Report that no pipeline was triggered.
- Auto-queue only definitions explicitly approved in the repository reference. For PlanningSpace, only build definition `892` is approved.
- Never queue deployment pipelines without explicit user authorization and required parameters.
- Do not expose access tokens, service-principal credentials, or masked log values.
- Treat `partiallySucceeded`, `failed`, `canceled`, and timed-out runs as non-success.
- If a run fails, retrieve the failed task timeline records and include the high-signal tail of each log.
- Route only deterministic code/test classifications to Developer. Infrastructure, credentials, unknown failures, and remediation-limit results require a different gate.
