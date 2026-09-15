---
name: ps-integration-architecture
description: Analyze architecture, data flow, contracts, or shared behavior between ps-excel-agent, Planning Space, and ps-app-delfi/FDPlan. Use for cross-repository scenario configuration, shared orchestrator behavior, API/model compatibility, integration design, or questions about how the Excel and Delfi agents complement each other.
---

# Planning Space integration architecture

1. Read [references/ecosystem.md](references/ecosystem.md).
2. Determine which repository is authoritative for the requested behavior.
3. Inspect both current repositories/packages when a change crosses their boundary; do not rely on the embedded summary alone.
4. Separate shared library behavior from repository-specific adapters and user interaction models.
5. Identify contract ownership, version compatibility, authentication identity, scenario semantics, and patch/merge behavior before proposing reuse.
6. For changes, create explicit compatibility and rollout steps rather than assuming both agents can update atomically.

The embedded ps-app-delfi knowledge is architectural context captured from an earlier repository state. Verify target framework, interfaces, pipeline steps, and model shapes in current source.
