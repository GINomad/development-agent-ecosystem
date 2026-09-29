# Hybrid Copilot / Codex instance

This branch starts from main and retains the PowerShell host, task clones, artifact validation, review verification, and explicit delivery gates. Copilot CLI is the implementation runtime; Codex owns independent control roles.

| Role | Runtime |
|---|---|
| Orchestrator | Copilot |
| Requirements research draft | Copilot, read-only tools |
| Requirements Analyst / final requirements | Codex |
| Developer, local tests, approved remediation | Copilot |
| Reviewer | Codex |
| Review Verifier | Codex |
| Knowledge Keeper | Copilot |
| Pipeline Monitor and guarded push | Codex, existing guarded scripts |
| Health Check and recovery | Codex |

Copilot drafts are evidence inputs, never approved requirements. Each provider must publish the normal role artifacts through the existing host scripts. Exit code zero or prose alone is insufficient. Review and verifier artifacts remain bound to the exact revision and public review hash. Copilot failures never silently switch the role to Codex.

## Start both instances

From the hybrid checkout:

~~~powershell
./scripts/Start-EcosystemInstance.ps1 -Instance hybrid
./scripts/Start-EcosystemInstance.ps1 -Instance classic -ClassicRoot C:/Repos/development-agent-ecosystem
~~~

Or use Start-Hybrid.cmd and Start-Classic.cmd on Windows. Add -NoOpen to suppress opening the browser. The launcher starts each dashboard in a hidden PowerShell process and returns its process ID and URL.

- Classic: http://127.0.0.1:43127/ and its existing state.
- Hybrid: http://127.0.0.1:43128/ and LOCALAPPDATA/Codex/development-agent-ecosystem-hybrid.
- Use -Port to select another free port. No source configuration is edited for this override.
- Use -PrepareOnly to inspect the paths and port without starting a process.
- The classic source files are executed from the original checkout. The hybrid launcher never copies modified scripts into it.
- Repeated launch of a live managed instance returns its existing process. A conflicting port or second classic controller is rejected rather than terminated.
- Generated agent definitions live under the hybrid state root. Knowledge resolves relative to the hybrid checkout; the trusted host synchronizes approved knowledge files with the classic checkout.
- Task ledgers, workspace leases, queues, metrics, and clones are separate. Scheduled tasks and global plugins are not installed by these launchers.
- Both instances may point at the same remote product repositories. Do not run the same delivery branch in both instances concurrently. Existing exact-origin and exact-commit delivery checks still apply.

The launcher stores its configuration snapshot, process identity, and local logs under .runtime/instances/<instance>. The session token in the dashboard log is local authorization material; do not share the raw log.

## Existing project knowledge

runtime.hybrid.knowledgeSourceRoot points to the classic checkout's knowledge/managed directory. Before each role starts, the hybrid host creates a fresh snapshot of global rules and projects/<selected-project> under that task's shared-knowledge directory. It includes current local files, including uncommitted records. Other projects and classic task runtime state are excluded.

Each snapshot includes shared-knowledge.json with original paths and SHA-256 fingerprints; copying verifies source and destination hashes. Snapshots are independent copies, so changes made in a snapshot cannot modify the source. Missing sources, linked filesystem entries, and files changing during copy stop snapshot preparation. The host never writes to the source knowledge directory.

Both Copilot and Codex receive the index and access to the snapshot. The requirements draft receives it too. Agents select relevant evidence instead of loading the entire database into the prompt, and must check provenance and resolve conflicting records. Existing global engineering standards are read from the snapshot. New verified hybrid knowledge is first published to the hybrid checkout's own versioned roots, then synchronized back by the trusted host after the Knowledge Keeper result passes validation.

Change knowledgeSourceRoot when moving the classic checkout. Validate snapshot refresh and source isolation with ./tests/Test-SharedKnowledge.ps1.
## Copilot installation and account

On Windows, the official install options are:

~~~powershell
winget install --id GitHub.Copilot --exact --source winget
~~~

Or, with Node 22+:

~~~powershell
npm.cmd install --global --prefix "$env:LOCALAPPDATA/Programs/copilot-cli" @github/copilot
& "$env:LOCALAPPDATA/Programs/copilot-cli/copilot.cmd" login --device-code
~~~

Authenticate in the browser with the account that owns the Copilot entitlement. Organizational policy must allow CLI access. Do not paste credentials into task prompts or configuration. The resolver supports PATH, the user-local npm location above, the standard npm location, and WinGet's executable link.

Run a small authenticated probe:

~~~powershell
./scripts/Test-CopilotConnection.ps1
~~~

The probe expects COPILOT_CLI_OK and records evidence under .runtime/copilot-connection. Authentication failure requires login; it is not repaired by changing source or switching to Codex. The provider model defaults to Copilot auto and can be selected through runtime.hybrid.copilotModel independently of Codex model tiers.

## Runtime and limits

Invoke-CopilotRole.ps1 passes a short prompt pointing to a scoped UTF-8 task-contract file. This avoids Windows command-line length limits for the full role prompt. It uses explicit programmatic mode, JSONL output, no remote export, an explicit tool list, scoped additional directories, and per-attempt usage files. The expanded contract file is removed when the attempt ends.

Requirements drafts have only view/grep/glob. Mutating roles receive local edit and shell tools needed for implementation and trusted host scripts. CLI tool filters and directory checks are not an operating-system sandbox; the role contracts, host artifact gates, and workstation policy remain authoritative. No blanket all-paths or all-URLs mode is enabled. Native provider tools differ from the standalone VS Code pack; these roles use full runtime prompts, not the standalone no-PowerShell profiles.

The runner enforces the existing wall-clock and identical-failure limits, maintains the task lease heartbeat, captures the final assistant message and usage file, and terminates its process tree on cancellation or timeout. It records provider selection separately from Codex model routing. No paid-role fallback is attempted.

For CLI startup/authentication/runtime failures, the host publishes a visible waiting-for-input question. Retry the affected role after resolving the problem; completed roles remain preserved. Invalid role artifacts still fail the existing terminal validation and follow the existing health workflow.

Automatic publication policy is configured separately from provider selection. Review approval, pipeline queue allowlists, and exact-origin checks must not be removed when enabling delivery.

## MCP in the hybrid runtime

Copilot now receives the task-bound ecosystem-read server through a per-attempt --additional-mcp-config file. Its tool allowlist matches the signed role session. The existing MCP roles remain Knowledge Keeper, Requirements Analyst, Reviewer and Review Verifier; the Copilot requirements draft uses the Analyst's read-only session. Developer, Orchestrator, Pipeline Monitor and Health Check retain their existing non-MCP role policies.

In addition to task state, public artifacts and pending comments, list_knowledge lists matching knowledge paths in pages of 40 and read_knowledge returns bounded text excerpts with source and SHA-256 evidence. Both providers in this hybrid checkout use these tools against the same selected-project snapshot. Binary attachments are indexed but require a suitable local viewer. Snapshot manifest and file hashes are verified before returning evidence; arbitrary paths and linked filesystem entries are rejected.

MCP remains read-only. The separate trusted-host synchronization described below publishes verified knowledge files to the classic knowledge directory; classic source code and runtime state remain unchanged. The server launches on demand over stdio for an active role; no extra public port is needed. Test-CopilotMcp.ps1 validates retrieval, scope and tamper rejection; add -Live for a licensed Copilot call. Copilot MCP events are included in the existing attempt metrics and failure checks.

CLI configuration follows https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers.
## Knowledge synchronization

knowledgeSyncEnabled enables automatic synchronization before each real role starts and after a successful, artifact-validated Knowledge Keeper outcome. Preparation-only runs do not synchronize. The shared source is knowledgeSourceRoot; the local copy is knowledge/managed. Only global knowledge and the selected project's directory participate. Task runtime state and .knowledge-import.json stay instance-local.

Before a role, shared changes are received when the local copy still matches the recorded common baseline. During first initialization, an unchanged local Git HEAD file can safely receive the shared version. Uncommitted shared knowledge and new attachments are included. Local edits are held for publication rather than sent implicitly.

After Knowledge Keeper completes, only targetPath files named by verified or superseded entries in its validated knowledge-update.json are eligible for reverse publication. Proposed entries are excluded; mixed proposed/verified entries targeting one file are rejected. The host synchronizes before allowing delivery continuation. Copilot never writes the shared root directly, and synchronization performs no git commit or push.

Concurrent modifications are detected using SHA-256 against a common baseline. Conflicting files are left unchanged and both copies are preserved in a conflict report. The task waits with a knowledge_sync_conflict question. Reconcile the two records, place the agreed content in both copies, then resume. Deletions are never propagated automatically. Every replaced destination has a backup, and file locks prevent overwriting concurrent open writers.

Reports, backups and common baselines are under the hybrid state root's knowledge-sync directory. Each task publication records its synchronization report in the task ledger. This is synchronization at role boundaries, not a continuous background watcher. Classic tasks already holding a context pack will see new knowledge when they next select or refresh context.

To receive existing knowledge manually from the hybrid checkout:

~~~powershell
./scripts/Invoke-HybridKnowledgeSync.ps1 -ProjectId planning-space
~~~

Run ./tests/Test-KnowledgeSync.ps1 for conflict, deletion, backup and publication tests.
## Validation

~~~powershell
./tests/Test-HybridRuntime.ps1
./scripts/Test-AgentEcosystem.ps1
~~~

The focused tests cover provider independence, legacy routing, large prompts and quoted paths, read-only draft tools, authentication failure, empty successful exits, and repeated tool failures. A mocked CLI test is not evidence of licensed service access: run the live connection probe separately. Validate a real end-to-end product task before relying on unattended delivery.

Official references checked 2026-09-24:

- https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
- https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference

