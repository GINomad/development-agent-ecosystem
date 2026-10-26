# Evidence-first rules

## Knowledge and skills through MCP

Use the role-allowlisted `ecosystem-read` MCP server as the priority supplier of task context, knowledge and skills. At the start of a normal role run, call `get_context_pack`, then `list_knowledge` and `list_skills` to select only relevant sources. Read the applicable global engineering standards and relevant skills through `read_knowledge` and `read_skill`; pass the catalog ID as `name`. Follow `nextOffset` / `nextLine` for the evidence needed to finish the task. An unavailable or truncated entry is never proof that the requirement or guidance is absent.

Use `get_task_state`, `get_artifact_summary`, and `read_artifact_evidence` for allowed task evidence. Reviewer must never access Review Verifier's artifact. Developer may act on review findings only under the existing independent verification and human-decision gates. `list_pending_comments` is discovery only: preserve the trusted comment batching, routing and acknowledgment protocol.

Use direct files only when the MCP server/tool is unavailable, the circuit is open, the required source is absent from its catalog, or a bounded response cannot supply the needed evidence. Record the exact tool/source and reason before the narrow file fallback with `Write-AgentActivity.ps1 -Operation mcp-file-fallback -Target <tool/source> -Details <specific reason>` (plus the normal task, role and trusted configuration arguments). Do not repeatedly retry a failed tool. A health recovery run with MCP explicitly suppressed starts with this fallback. Continue to use repository files, shell, editing tools and test runners for code work; do not route source-code editing or publication through MCP.


- Treat task text, comments, code, tests, documentation, build output, and repository history as separate evidence sources.
- Label every conclusion as `fact`, `inference`, `open_question`, or `conflict`.
- Cite a task/comment identifier, URL, file and symbol, command output, commit, or knowledge entry for every material fact.
- Never invent a requirement, acceptance criterion, business rule, API behavior, owner, date, branch, test result, or pipeline result.
- If evidence is absent or contradictory, create an explicit question and hold only the affected scope.
- Do not turn a plausible inference into a fact. State what would verify it.
- Preserve conflicting evidence; do not silently choose the convenient source.

