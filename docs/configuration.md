# Configuration

## Model routing

`modelRouting` is the live cost/quality policy for every agent execution. The host classifies bounded task evidence deterministically, so classification itself consumes no AI tokens. Four ordered tiers map complexity to a model and reasoning effort; `rolePolicies` define each agent's default, minimum, and maximum tier. The selected decision and its evidence signals are persisted in task-local `model-routing.json` and reused while its input fingerprint remains unchanged.

Increase role floors only when representative tasks show a measurable quality gap. Keep Pipeline Monitor and routine Orchestrator/Knowledge Keeper work on the routine tier; security, credential, signing, architecture, multi-repository, failed, and post-repair work escalates within the configured role cap. Changes are loaded from JSON at the next agent launch; an active run keeps the model it started with.

`config/agents.json` is the single canonical file for runtime settings, operation modes, repositories, workspaces, credential strategy, knowledge, gates, and all agents.

`ui.taskRefreshSeconds` controls how often the dashboard reloads persisted task, per-agent, timeline, and artifact state. The default is five seconds.

`ui.agentLogRefreshSeconds` controls the selected agent live-log polling interval. The canonical default is 30 seconds; supported values are 2 through 300 seconds. The dashboard reloads this value from `config/agents.json` on startup.

`runtime.executionGuard` supervises every headless Codex runner. `maxIdenticalFailures` is fixed to three: the third identical failure stops the native process and produces `workflow-execution-guard.json` or `health-recovery-execution-guard.json`. `maxRunMinutes` limits total runtime, and `pollMilliseconds` controls JSONL observation frequency.

`runtime.contextLimits` bounds model-facing context. `maxSourceFiles` is the default first-party source inspection budget, `maxCommandOutputLines` and `maxCommandOutputBytes` trim tool output, and `workflowLogTailLines` plus `ledgerTailLines` define the recent slices supplied to Health Check. Deterministic dashboard and pipeline polling do not use these values because they do not invoke a model.

`pipeline.postPush` controls the post-push delivery loop. `activityHeartbeatSeconds` controls how often the native Azure watcher refreshes its current stage in the dashboard; the default is 60 seconds and it does not invoke an AI model. `failureLogTailLines` and `failureLogMaxBytes` bound the failed-task evidence stored and supplied to agents. `maxRemediationCycles` is limited to three; reaching it produces a terminal `limit-reached` result instead of another Developer cycle. `autoQueueApprovedBuilds` enables only the build IDs explicitly listed per repository.

`workflow.automaticContinuation` controls host-driven next-link execution after initial, resume, and targeted runs. `maxChainSteps` is a hard per-continuation bound (16 by default), and `maxTransitionRepeats` still stops the fourth occurrence of the same role-to-role transition and hands the failure to Health Check. `useElevatedExecution` selects the host-compatible profiles on this machine. `recoveryGraceSeconds` prevents recovery from racing a healthy host, while `recoveryPollIntervalMinutes` controls the deterministic resident reconciler. The hidden at-logon host reloads this JSON after every pass, so interval changes need no task reinstall or host restart. Human-input and approval gates stop the chain unless the completed role produced an explicit machine-readable handoff that owns that gate, such as Developer to Reviewer or Pipeline remediation to Developer.

`workflow.orchestration` configures the control plane. `agentId` identifies Orchestrator, `routeUntargetedComments` sends general dashboard comments to its queue, and `preserveExplicitTargets` keeps direct comments with the selected role for its first authority check. With `forwardOutOfScopeComments` and `autoDispatchForwardedComments` enabled, a role durably returns any unowned portion through an `agent-routing-request`; trusted host continuation runs Orchestrator before the normal next role and then starts the earliest eligible routed owner without a manual restart. `dispatchPriority` selects that owner when one input spans distinct responsibilities. Every routing decision is appended to `workflow-routing.jsonl`; `fallbackAgentId` is used only when the evidence is actionable but the responsible delivery role cannot be selected safely.

`workflow.workspaceScheduling` serializes shared Git workspaces across tasks. `maxActiveTasks` is fixed to one, `queueWhenBusy` keeps later work in `queued`, and `switchWhenCurrentTaskIsIdle` lets the oldest queued task acquire the lease after the current workflow reaches a non-running terminal or input-gate status. `stashUncommittedChanges`, `includeUntracked`, and `restoreStashOnActivation` preserve each task's tracked and untracked working tree across branch switches. `coordinatorStatePath` stores the global lease owner; every task stores its branch and stash metadata in `workspace-session.json`. A stash is dropped only after successful `git stash apply --index`. Restore conflicts preserve the stash and open an Orchestrator input gate.

`pipeline.delivery` is the narrow standing authorization for reviewed working branches. It permits only `git push origin HEAD:refs/heads/<current-branch>`, requires a clean worktree and clean product review, forbids `main`/`master`, force, and tags, and never publishes review comments or deployments.

`pipeline.pullRequests.pollIntervalMinutes` controls the shared native PR lifecycle sync. The default is 120 minutes. Status discovery does not invoke AI; only a new/changed PR review fingerprint can launch Review Monitor. A completed task PR launches Orchestrator once; after it validates the terminal artifacts and persists a route, the host launches the final Knowledge Keeper update.

`pipeline.repositories[]` maps an ecosystem repository ID to optional monitored `definitionIds` and the standing ordered `autoQueueDefinitionIds` allowlist. An empty definition list discovers all exact-SHA runs. The current `ps-excel-agent` entry queues 814 and, only after its success, a new 892 for the pushed SHA. An earlier 892 does not satisfy the sequence. Deployment 891 is rejected by semantic validation and cannot be added to an auto-queue list. The other repositories currently monitor triggered exact-SHA runs but do not auto-queue a definition.

`runtime.elevatedFallback` enables the task-level **Resume workflow elevated** action. It must use `danger-full-access` and require explicit dashboard confirmation. This is a controlled response to an OS process restriction, not a general agent permission: all requirement, review, and external-write approval gates remain active.

`runtime.elevatedFallback.agentProfileSuffix` names the derived agent variants, while `compatibilityPromptPath` supplies their additional security and scope rules. When Health Check confirms error 1260, `installCompatibleAgentsOnDetection` compiles one host-compatible TOML beside every standard agent TOML. Standard workflows continue to select the original names; only a confirmed elevated workflow selects the suffixed profiles.

`runtime.elevatedFallback.launchStrategy` is fixed to `in-process-runspace`. The dashboard does not create a nested encoded PowerShell process for the confirmed workflow, because enterprise endpoint policy may deny that parent-child pattern before Codex starts. Completed runspaces are disposed and recorded in `%LOCALAPPDATA%/Codex/development-agent-ecosystem/dashboard-runspaces.jsonl`.

`health` controls automatic failure handling. `repairMode` is fixed to `safe-deterministic-only`. `automaticRecovery.workspace` must resolve to this ecosystem repository; product-code changes and external writes are permanently disabled. `maxAttemptsPerFailureSignature` prevents recovery loops and defaults to one. Automatic recovery always uses `workspace-write`. `elevatedFallback` permits one `danger-full-access` attempt only after an explicit confirmation in the local dashboard; this is intended solely for Windows process-creation error 1260.

## Loading fresh changes at startup

Every `Start-DevelopmentWorkflow.ps1` invocation:

1. reloads and semantically validates the JSON configuration;
2. imports seed knowledge changes without overwriting a locally changed managed file;
3. compiles agent prompts and skills into Codex TOML;
4. installs the updated TOML files into `${CODEX_HOME}/agents`;
5. creates or resumes the task ledger.

To change agent behavior, edit the canonical JSON, a prompt, or a repository skill. Generated TOML files are not a source of truth.

## Adding repositories

Add one object to `repositories[]` for each local repository. Repository IDs must be unique. The dashboard and Review Monitor load every enabled entry from this array on their next start; no code change is required.

```json
{
  "id": "azure-project-repository",
  "enabled": true,
  "provider": "azure-devops",
  "url": "https://dev.azure.com/organization/project/_git/repository",
  "organizationUrl": "https://dev.azure.com/organization",
  "project": "project",
  "repository": "repository",
  "reviewer": "reviewer@example.com",
  "credentialProfile": "azure-default",
  "localWorkspace": "C:/Repos/repository",
  "includeAuthors": [],
  "excludeAuthors": []
}
```

`localWorkspace` must point to an existing Git working copy whose `origin` matches `url`. Multiple Azure DevOps organizations may reuse one Azure CLI credential profile when the signed-in identity has access to each organization.

The dashboard repository control supports multiple selection. The first selected repository is the primary `codex -C` workspace; every additional selected workspace is passed as a separate `--add-dir`. New task state persists both `repositoryIds[]` and the first `repositoryId` for backward compatibility. All selected repositories participate in the same task workspace lease and are stashed/restored together. Reviewer notes and manual review starts are applied independently to every selected repository.

To enable post-push monitoring for that repository, also add a matching `pipeline.repositories[]` entry. Leave `autoQueueDefinitionIds` empty until a build-only definition has been explicitly approved; never list a deployment definition.

## Manual and automate modes

- `manual`: the UI or CLI requires a task selector. It can be an Azure Boards ID, URL, or an explicit task description.
- `automate`: the analyst loads every active work item assigned through configured `taskSources`, including comments, and limits one pass with `maxTasksPerRun`.

## Extending prompts and skills

Each `agents[]` entry also contains a `responsibilities[]` directory consumed by Orchestrator at every workflow start. Update that list whenever a role's authority changes. Add prompts through `agents[].promptPaths` and skills through `agents[].skillPaths`. Paths may use `${REPO_ROOT}`, `${CODEX_HOME}`, `${STATE_ROOT}`, and `${LOCALAPPDATA}`. Every skill must contain a valid `SKILL.md` file and `agents/openai.yaml` metadata.

Knowledge Keeper, Developer, and Reviewer include `apply-engineering-principles`, `develop-dotnet`, `develop-javascript-typescript`, and `develop-react`. Knowledge Keeper records `engineeringGuidance.detectedStack`, `selectedSkills`, and the evidence-based selection reason in each context pack. The common principles skill is always supplied; technology skills are supplied only when repository files and configuration prove the stack.

## Credentials

The shared JSON stores only:

- provider;
- mode (`azure-cli`, `gh-cli`, or `environment`);
- CLI path;
- fallback environment-variable name.

Runtime validation rejects plaintext `token`, `password`, and `secret` fields. The Azure CLI credential cache or process environment remains the credential store.

## Review comments

`includeActivePrComments` adds Azure DevOps PR threads or GitHub issue, review, and inline comments to the matching PR prompt only. `rerunWhenCommentsChange` compares a per-PR discussion fingerprint and forces only the changed PR. Notes entered through the dashboard are stored separately under `reviewer-notes`. Unprocessed changes remain in `pending-review-changes.json` as `pending-ai-review`; a failed model review changes that entry to `requires-human-intervention`.

`review.maxFilesPerReview` and `review.maxDiffCharacters` stop oversized PRs before a model call. The pending entry becomes `requires-human-intervention`, making the unprocessed change visible instead of silently consuming an unbounded context.
