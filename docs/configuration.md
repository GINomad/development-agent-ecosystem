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

`pipeline.ownership` is the mandatory role map for pipeline work. Pipeline Monitor owns guarded delivery, exact-SHA observation, and PR state; Developer owns evidence-supported product code/test/YAML remediation; Reviewer owns remediation review; Orchestrator owns exception routing and terminal validation; Health Check owns ecosystem defects only; Knowledge Keeper owns final publication. Schema and semantic validation require all six configured IDs and reject reassignment through ad hoc task text. See the [pipeline monitoring and ownership matrix](pipeline-monitoring.md).

`workflow.automaticContinuation` controls host-driven next-link execution after initial, resume, and targeted runs. `maxChainSteps` is a hard per-continuation bound (16 by default), and `maxTransitionRepeats` still stops the fourth occurrence of the same role-to-role transition and hands the failure to Health Check. `useElevatedExecution` selects the host-compatible profiles on this machine. `recoveryGraceSeconds` prevents recovery from racing a healthy host, while `recoveryPollIntervalMinutes` controls the deterministic resident reconciler. The hidden at-logon host reloads this JSON after every pass, so interval changes need no task reinstall or host restart. Human-input and approval gates stop the chain unless the completed role produced an explicit machine-readable handoff that owns that gate, such as Developer to Reviewer or Pipeline remediation to Developer.

`workflow.orchestration` configures the control plane. `agentId` identifies Orchestrator, `routeUntargetedComments` sends general dashboard comments to its queue, and `preserveExplicitTargets` keeps direct comments with the selected role for its first authority check. `executionModes` defines the permitted ordered agents, whether product code changes are allowed, and whether the trusted host may continue automatically. Orchestrator chooses the narrowest mode from the requested outcome; for example, `research-only` runs Requirements Analyst and stops without Developer, Reviewer, or Pipeline Monitor. Each route persists the selected mode and sequence in `workflow-routing.jsonl`; legacy routes default to `full-delivery`. With `forwardOutOfScopeComments` and `autoDispatchForwardedComments` enabled, a role durably returns any unowned portion through an `agent-routing-request`; trusted host continuation runs Orchestrator before the normal next role and then starts the earliest eligible routed owner without a manual restart. `dispatchPriority` selects that owner when one input spans distinct responsibilities. `fallbackAgentId` is used only when it belongs to the selected mode and the evidence is actionable but ownership remains unclear.

`workflow.workspaceScheduling` serializes shared Git workspaces across tasks. `maxActiveTasks` is fixed to one, `queueWhenBusy` keeps later work in `queued`, and `switchWhenCurrentTaskIsIdle` lets the oldest queued task acquire the lease after the current workflow reaches a non-running terminal or input-gate status. `stashUncommittedChanges`, `includeUntracked`, and `restoreStashOnActivation` preserve each task's tracked and untracked working tree across branch switches. `coordinatorStatePath` stores the global lease owner; every task stores its branch and stash metadata in `workspace-session.json`. A stash is dropped only after successful `git stash apply --index`. Restore conflicts preserve the stash and open an Orchestrator input gate.

`pipeline.delivery` is the narrow standing authorization for reviewed working branches. It permits only `git push origin HEAD:refs/heads/<current-branch>`, requires a clean worktree and clean product review, forbids `main`/`master`, force, and tags, and never publishes review comments or deployments.

`pipeline.pullRequests.pollIntervalMinutes` controls the shared native PR lifecycle sync. The default is 120 minutes. Status discovery does not invoke AI; only a new/changed PR review fingerprint can launch Review Monitor. A completed task PR launches Orchestrator once; after it validates the terminal artifacts and persists a route, the host launches the final Knowledge Keeper update.

`pipeline.repositories[]` maps an ecosystem repository ID to optional monitored `definitionIds` and the standing ordered `autoQueueDefinitionIds` allowlist. An empty definition list discovers all exact-SHA runs. The current `ps-excel-agent` entry queues 814 and, only after its success, a new 892 for the pushed SHA. An earlier 892 does not satisfy the sequence. Deployment 891 is rejected by semantic validation and cannot be added to an auto-queue list. The other repositories currently monitor triggered exact-SHA runs but do not auto-queue a definition.

`runtime.elevatedFallback` defines host-compatible execution. The standing configuration requires `useByDefault=true`, `requiresDashboardApproval=false`, and `sandboxMode=danger-full-access`, so CLI, continuation, targeted resume, and Health paths select the compatible profile without waiting for an OS error. The dashboard still shows its own warning before explicit elevated start/recovery controls. This is an execution profile, not a general agent permission: all requirement, review, credential, and external-write gates remain active.

`runtime.elevatedFallback.agentProfileSuffix` names the derived agent variants, while `compatibilityPromptPath` supplies their additional security and scope rules. Workflow startup or Health Check compiles one host-compatible TOML beside every standard agent TOML. With the standing default, workflows select the suffixed profiles; standard definitions remain available for rollback and diagnostics.

`runtime.elevatedFallback.launchStrategy` is fixed to `in-process-runspace`. The dashboard does not create a nested encoded PowerShell process for the confirmed workflow, because enterprise endpoint policy may deny that parent-child pattern before Codex starts. Completed runspaces are disposed and recorded in `%LOCALAPPDATA%/Codex/development-agent-ecosystem/dashboard-runspaces.jsonl`.

`health` controls automatic failure handling. `repairMode` is fixed to `safe-deterministic-only`. `automaticRecovery.workspace` must resolve to this ecosystem repository; `allowEcosystemSourceChanges=true` permits the bounded recovery coordinator to edit it, while product-code changes and model-driven external writes remain disabled. `preserveDirtyWorktreeChanges=true` makes the trusted host commit every tracked and untracked non-ignored dirty change before recovery and record the exact baseline. After complete validation, `commitVerifiedRepairs=true` creates a separate repair commit when needed. `pushVerifiedRepairs=true` permits a normal non-force, non-tag push only to the exact `pushRemote=origin` and `pushRemoteUrl`, only on a non-base branch, followed by exact remote-SHA verification of the final commit chain. `maxAttemptsPerFailureSignature` prevents recovery loops and defaults to one. Standing `elevatedFallback.useByDefault=true` selects `danger-full-access` for workflow and Health processes to avoid Windows process-creation error 1260; role and external-write gates remain enforced by the control plane.

## Knowledge scope

`knowledge.globalStandardsPath` points to the versioned engineering standards applied to every configured repository. Confirmed review guidance about code organization, formatting, naming, access modifiers, member ordering, braces, testing style, maintainability, and engineering principles is promoted there, or to a technology-scoped section, after applicable implementation and a clean review. Business rules, domain behavior, API contracts, integrations, and product-specific decisions stay under repository-scoped managed knowledge. Bypassed, deferred, rejected, unresolved, speculative, and explicitly task-only comments are not promoted.

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

Do not add per-repository role overrides. All repositories use the validated global `pipeline.ownership` chain; only observed and auto-queued definition IDs vary per repository.

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
