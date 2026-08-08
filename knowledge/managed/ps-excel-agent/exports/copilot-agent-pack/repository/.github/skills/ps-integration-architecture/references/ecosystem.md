# Planning Space integration ecosystem

## Roles

`ps-excel-agent` is user-driven:

- Excel workbooks are the primary input/output surface.
- Office.js custom functions and task pane submit work on demand.
- The ASP.NET backend mediates Planning Space calculations and API calls.

`ps-app-delfi` is event-driven:

- FDPlan/Delfi events are the primary input.
- Background services orchestrate discovery, retrieval, conversion, Planning Space setup/calculation, result retrieval, upload, and completion.
- It maintains more persistent event-processing state and broader FDPlan/Planning Space client contracts.

Both integrate with Planning Space and may share orchestration packages, model semantics, OAuth/JWT concerns, retry/throttling patterns, hierarchy/project/variable concepts, and environment configuration.

## Cross-repository analysis checklist

- Which repository owns the inbound schema?
- Which shared NuGet package owns the Planning Space API contract?
- Are both repositories using the same package version?
- Is the scenario setting global per request, per project, or per variable?
- Does a patch merge or replace complete settings/scenarios/variables collections?
- Are authentication tokens user-delegated, exchanged, or service credentials?
- Are retries safe for the operation and token-rotation model?
- Can rollout be backward compatible if only one agent updates first?

## ps-app-delfi architecture context

Historical documentation described an ASP.NET Core API plus background services with:

- an event processor orchestrating a multi-phase FDPlan-to-Planning-Space pipeline;
- FDPlan, Planning Space, and dataflow client interfaces;
- conversion layers for economic variables and results;
- storage for event/configuration state;
- retries, throttling, structured logging, and OpenTelemetry;
- MSTest/Moq test projects.

Historical C# conventions included constructor injection, async all the way, structured logging, one type per file, file/folder-aligned namespaces, public API XML docs, and explicit secret/configuration separation. Apply current repository conventions when they conflict.

## Shared scenario caution

Earlier investigation found that a shared orchestrator/project patch path could replace complete scenario arrays. A per-project or multi-scenario feature therefore cannot be designed only at the Excel-range layer. Trace the full converter/orchestrator/controller call chain and establish merge semantics in both agents.
