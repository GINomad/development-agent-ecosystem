# Canonical knowledge catalog

Root:

```text
C:\Repos\AI Knowledge\ps_excel_agent
```

## General project knowledge

- `coding-style.md`: explicit style and review preferences.
- `coding-knowledge.md`: durable implementation decisions and rejected approaches.
- `knowledge-discovery.md`: repository layout, stack, runtime boundaries, integrations, and risky areas.
- `docker-update.md`: Docker, runtime configuration, pipeline, deployment, and CORS investigation history.

## Authentication and Office runtime

- `conversation history\auth-refresh-cold-start.md`: token rotation, parallel refresh, UI/backend contract, and AsyncLocal lessons.
- `conversation history\1839566-[Auth] Keep auth alive in Synchronous method.md`: synchronous/VBA auth feasibility and implementation history.
- `conversation history\excel-custom-functions-cancellation.md`: cancellation lifecycle, rejected Office shortcut approaches, final VBA bridge, and worksheet-scoped concept.

## Scenarios and input contracts

- `conversation history\1813945-Define scenario for projects and variables.md`: original scenario data flow.
- `conversation history\1838084-Per-row ProjectScenarioName override and Scenario Configuration feasibility (ps-excel-agent).md`: Excel-agent feasibility and shared orchestrator risks.
- `conversation history\1838084-[Inputs] Support per-project scenario targeting and configuration.md`: final/non-final scenario decisions, EMV deferral, separate ranges, and global/per-project fallback.
- `Transcripts\Single-row scenario.txt`: raw discussion evidence; use only when summaries are insufficient.

## ps-app-delfi ecosystem

- `ps-app-delfi_INDEX_AND_SUMMARY.md`: starting index.
- `ps-app-delfi_ARCHITECTURE_OVERVIEW.md`: components and system architecture.
- `ps-app-delfi_API_CONTRACTS_AND_INTERFACES.md`: client/service contracts.
- `ps-app-delfi_CODE_STYLE_AND_CONVENTIONS.md`: repository-specific C# conventions.
- `ps-app-delfi_DATA_FLOW_AND_EVENT_PROCESSING.md`: detailed event pipeline.
- `ps-app-delfi_DEPENDENCIES_AND_TECH_STACK.md`: dependency inventory.
- `ps-app-delfi_RELATIONSHIP_TO_PS_EXCEL_AGENT.md`: shared concerns and integration opportunities.

## PR review agent

- `conversation history\local-pr-review-agent.md`: local review-agent summary.
- `exports\azure-pr-review-agent`: distributable Azure/GitHub PR review monitor.

## Reading rules

- Search by symptom, class/member name, ticket number, and decision keyword.
- In chronological documents, prefer the latest explicit final direction over earlier experiments.
- Verify claims against the active branch before implementing them.
