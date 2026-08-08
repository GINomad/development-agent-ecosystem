# Configuration

`config/agents.json` is the single canonical file for runtime settings, operation modes, repositories, workspaces, credential strategy, knowledge, gates, and all agents.

`ui.taskRefreshSeconds` controls how often the dashboard reloads persisted task, per-agent, timeline, and artifact state. The default is five seconds.

`ui.agentLogRefreshSeconds` controls the selected agent live-log polling interval. The canonical default is 30 seconds; supported values are 2 through 300 seconds. The dashboard reloads this value from `config/agents.json` on startup.

`runtime.executionGuard` supervises every headless Codex runner. `maxIdenticalFailures` is fixed to three: the third identical failure stops the native process and produces `workflow-execution-guard.json` or `health-recovery-execution-guard.json`. `maxRunMinutes` limits total runtime, and `pollMilliseconds` controls JSONL observation frequency.

`runtime.contextLimits` bounds model-facing context. `maxSourceFiles` is the default first-party source inspection budget, `maxCommandOutputLines` and `maxCommandOutputBytes` trim tool output, and `workflowLogTailLines` plus `ledgerTailLines` define the recent slices supplied to Health Check. Deterministic dashboard and pipeline polling do not use these values because they do not invoke a model.

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

The dashboard repository control supports multiple selection. The first selected repository is the primary `codex -C` workspace; every additional selected workspace is passed as a separate `--add-dir`. New task state persists both `repositoryIds[]` and the first `repositoryId` for backward compatibility. Reviewer notes and manual review starts are applied independently to every selected repository.

## Manual and automate modes

- `manual`: the UI or CLI requires a task selector. It can be an Azure Boards ID, URL, or an explicit task description.
- `automate`: the analyst loads every active work item assigned through configured `taskSources`, including comments, and limits one pass with `maxTasksPerRun`.

## Extending prompts and skills

Add a path to `agents[].promptPaths` or `agents[].skillPaths`. Paths may use `${REPO_ROOT}`, `${CODEX_HOME}`, `${STATE_ROOT}`, and `${LOCALAPPDATA}`. Every skill must contain a valid `SKILL.md` file and `agents/openai.yaml` metadata.

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
