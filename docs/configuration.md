# Configuration

`config/agents.json` is the single canonical file for runtime settings, operation modes, repositories, workspaces, credential strategy, knowledge, gates, and all agents.

## Loading fresh changes at startup

Every `Start-DevelopmentWorkflow.ps1` invocation:

1. reloads and semantically validates the JSON configuration;
2. imports seed knowledge changes without overwriting a locally changed managed file;
3. compiles agent prompts and skills into Codex TOML;
4. installs the updated TOML files into `${CODEX_HOME}/agents`;
5. creates or resumes the task ledger.

To change agent behavior, edit the canonical JSON, a prompt, or a repository skill. Generated TOML files are not a source of truth.

## Manual and automate modes

- `manual`: the UI or CLI requires a task selector. It can be an Azure Boards ID, URL, or an explicit task description.
- `automate`: the analyst loads every active work item assigned through configured `taskSources`, including comments, and limits one pass with `maxTasksPerRun`.

## Extending prompts and skills

Add a path to `agents[].promptPaths` or `agents[].skillPaths`. Paths may use `${REPO_ROOT}`, `${CODEX_HOME}`, `${STATE_ROOT}`, and `${LOCALAPPDATA}`. Every skill must contain a valid `SKILL.md` file.

## Credentials

The shared JSON stores only:

- provider;
- mode (`azure-cli`, `gh-cli`, or `environment`);
- CLI path;
- fallback environment-variable name.

Runtime validation rejects plaintext `token`, `password`, and `secret` fields. The Azure CLI credential cache or process environment remains the credential store.

## Review comments

`includeActivePrComments` adds Azure DevOps PR threads or GitHub issue, review, and inline comments to the review prompt. `rerunWhenCommentsChange` includes a discussion hash in the revision key. Notes entered through the dashboard are stored separately under `reviewer-notes` and attached to the selected repository, PR, or task.
