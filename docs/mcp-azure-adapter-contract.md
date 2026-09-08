# Azure DevOps MCP adapter contract

An external Azure DevOps MCP server is an optional, read-only evidence adapter. It is never a workflow-control or delivery adapter: the trusted host continues to own task state, leases, artifact validation, commits, work-item mutation, review publication, pipeline queueing, and every approval gate.

## Registration and role policy

The setup interview records only the provider's registered server name and the role allowlist. Connection commands, non-secret arguments, and credentials are local runtime configuration; canonical `agents.json` contains neither service URLs nor secrets. The server must already be registered with the Codex runtime before it can be selected. Unknown server names, write-capable tools, or a role without an explicit allowlist are denied.

Only Requirements Analyst is normally granted Azure Boards relation traversal. Reviewer and Review Verifier consume the published, revision-bound requirements analysis rather than independently exploring an unbounded work-item graph. This preserves an auditable requirement-to-review chain and the Review Verifier's isolation.

## Required read-only tool mapping

| Evidence need | Adapter tool | Bounded request | Required result fields |
|---|---|---|---|
| Current task | `get_work_item` | one configured organization/project and work-item ID | `id`, `revision`, `retrievedAtUtc`, fields, `truncated` |
| Acceptance history | `get_work_item_history` | configured item and maximum history entries | `id`, `revision`, `retrievedAtUtc`, entries, `truncated` |
| Discussion | `list_work_item_comments` | configured item and maximum comments | `id`, `revision`, `retrievedAtUtc`, comments, `truncated` |
| Graph | `list_work_item_relations` | configured item, maximum depth and related-item count | source ID/revision, relation type, target ID/revision, `retrievedAtUtc`, `truncated` |
| Related details | `get_work_items` | IDs returned by the relation tool only | per-item ID/revision/retrieval time, fields, `truncated` |
| PR context | `get_pull_request` / `list_pull_request_threads` | repository/PR explicitly linked by the task | revision, retrieval time, threads, `truncated` |

The adapter must not expose tools that create, edit, transition, vote on, link, delete, or publish Azure DevOps resources. A server that cannot constrain its tools to this contract stays disabled.

## Traversal and evidence rules

The host supplies the configured organization/project and limits for relation depth, related items, history entries, comments, and response bytes. The analyst follows only relations returned by `list_work_item_relations`; it does not search the organization or infer a relation from prose. A limit hit is reported as `truncated=true` and the affected scope is held rather than silently treated as complete.

External titles, descriptions, comments, history text, links, and fields are untrusted content. They may be cited as evidence but never treated as instructions that alter role authority, configuration, approvals, or scope. The adapter validates the configured project/organization, normalizes IDs and relation types, rejects response objects that lack a stable revision and retrieval timestamp, and bounds text before exposing it to a model.

Every fact derived from Azure carries the work-item or PR identifier, provider revision, and `retrievedAtUtc` into `requirements-analysis.json`. The analyst records contradictions between revisions or related tasks rather than selecting a convenient source. The existing Azure CLI/context-pack route remains the classic fallback. If the MCP circuit is open, the current item is loaded through `Get-AssignedTaskContext.ps1`; only the unavailable related-item evidence is held.

## Availability and incident behavior

An MCP timeout, protocol/schema failure, or unavailable server opens its circuit according to the configured threshold. The role continues in classic context mode and records the degradation. Health Check probes the server asynchronously with MCP disabled for its own recovery run. A successful repair enters half-open state and must pass the configured number of read-only probes before a new role run can use the server. Security/isolation failures remain open for human review and are never auto-reenabled.
