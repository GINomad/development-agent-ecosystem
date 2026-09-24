<!-- development-agent-standalone:start -->
# Standalone development agents for Copilot

Use the narrowest suitable role. For substantial work that benefits from coordination, select `development-workflow-orchestrator`; it can invoke the seven specialists. Simple tasks can stay in the current conversation.

| Request | Agent |
|---|---|
| Requirements, acceptance criteria, unclear scope | development-requirements-analyst |
| Authorized implementation or fixes | development-implementer |
| Independent code review | development-reviewer |
| Falsify findings and verify coverage | development-review-verifier |
| External verified project context and completed outcomes | development-knowledge-keeper |
| Requested CI observation for an exact pushed SHA | development-pipeline-monitor |
| Agent configuration or skill failures | development-health-check |
| Multi-stage ownership and coordination | development-workflow-orchestrator |

For substantial implementation, normally use analyst -> implementer -> reviewer -> independent verifier. Preserve held scope. Review-only requests stop after verification unless fixes were also authorized. Handoffs and subagent selection are not authorization to publish, push, queue, deploy, or mutate work items.

Knowledge Keeper alone maintains generated knowledge under `~/.copilot/development-agent-knowledge/`, separated by project. Read only relevant verified context before work and record only verified completed outcomes afterwards. Never store generated memory or history inside a product repository. If the external root cannot be accessed, report that persistence is unavailable.

These are standalone VS Code profiles. They do not activate the Codex runtime configuration, dashboard, task ledger, scheduled continuation, automatic delivery, or recovery. Do not run PowerShell or ecosystem scripts from these agents. Missing tools, policy denials, and inaccessible private CI are explicit limitations, not successful checks.
<!-- development-agent-standalone:end -->
