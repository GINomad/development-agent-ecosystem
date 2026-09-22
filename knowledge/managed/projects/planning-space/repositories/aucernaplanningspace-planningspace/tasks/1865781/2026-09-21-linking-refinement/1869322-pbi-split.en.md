# 1869322 — Proposed PBI split: acceptance criteria and implementation plans

Status: planning draft, not ADO-created stories. Supersedes the earlier short six-story breakdown, not the original evidence snapshot. Desktop is the accepted business-behavior reference. Unknowns below remain open; no example, suggestion, or test expectation resolves them by implication.

Estimates include Dev/review/automated tests/QA;1SP=4h. Both planning scenarios remain200h/50SP total:8+10+8+8+8+8SP. These are provisional budgets, not proof that unresolved behavior fits the allocation.

## Shared implementation context

Repository: https://dev.azure.com/Aucerna/PlanningSpace/_git/PlanningSpace. Inspected local baseline:db7f87c7209b5897bba21df7d98a0e0081b58cef. Before implementation refresh source and ADO descriptions/comments; do not assume this snapshot is current. Existing uncommitted web prototype is evidence of feasibility only; preserve others' changes.

Source anchors, relative to repository root:
- Fusion/Framework/Report.Entities/Entities/StandardReportVariableLink.cs — link model, named-range convention and legacy serialization.
- Fusion/Framework/Report.Entities/Entities/EditableStandardReportEntity.cs — workbook Template and separate VariableList.
- Fusion/Framework/Report.DataAccess/DBRepository/EditableStandardReportDBRepository.cs — persistence of both components.
- Fusion/Components/Administration/ViewModels/Reports/ReportTemplateEditorViewModel.cs — desktop commands, save/update permission and business lock lifecycle.
- Fusion/Components/Administration/ViewModels/Reports/ReportTemplateSpreadsheetHelper.cs — workbook/link presentation and range operations.
- Fusion/Components/Administration/ViewModels/Reports/ReportVariableLinkSettingsViewModel.cs — conditional property availability.
- Fusion/Framework/ReportGenerator/PseudoVariableValueProvider/CommonPseudoVariableValueFactory.cs and VariableLinkPopulator/Implementation/ — existing generation semantics.
- Web/economics/src/app/report/resultset-view/report-view/ and Fusion/Fusion.ServiceModel.Services.Web/Controllers/ReportSpreadsheetController.cs — existing viewer/host integration; not a completed template editor.

Line numbers in the original report are baseline hints, not stable API contracts. Reuse existing services and authorization patterns after inspection. This plan does not invent endpoint names, DTO shapes, component APIs or database migrations.

Shared prerequisites: accepted web component/host approach; server-authorized open/save service with existing business locks; access to workbook selection and persistent named ranges; agreed template/link representation. Their general implementation is covered by the separate Feature foundation estimate. Each story owns its domain mapping and tests, not a duplicate save infrastructure.

For every story: preserve workbook bytes AND corresponding link metadata; validate using a fresh reopen rather than the current in-memory object. Use existing report generator for compatibility tests, without adding execution UI. POC value insertion must not be mistaken for link creation. Do not expose legacy binary deserialization as a new untrusted public input.

An unresolved item blocks only the affected behavior. Code inspection or a reproducible desktop example can resolve implementation facts; record file/revision and test evidence before converting the corresponding question into an AC. If code, desktop behavior, and current requirements disagree, retain the question for the owner. Do not guess or silently select convenient behavior.

## L1 — Browse and filter report variables

Estimate O/P:32h /8SP.

### Proposed acceptance criteria — known scope
- AC1: Opening the variable panel for a template displays variables from the selected regime, grouped into the desktop-defined Summary/Periodic and metadata categories. The UI uses real domain identifiers, not display text as identity.
- AC2: For a fixed regime and a known fixture catalog, search narrows the displayed results. Clearing search restores the regime-scoped results without changing existing links or workbook contents.
- AC3: For a template fixture with one linked and one unlinked variable, All displays both eligible variables; Linked displays only the linked variable. Multiple links for one variable do not turn it into different domain variables.
- AC4: Search and All/Linked operate together within the selected regime. A successful link creation/removal refreshes the Linked view from the current link model, including after save/reopen.
- AC5: Browsing and filtering alone do not create, delete, or modify template links.

### Implementation plan
1. Trace the desktop variable-tree provider and its callers; identify regime scoping, variable identity, categories, and which metadata is eligible for each report type. Record actual provider/API names in implementation notes.
2. Locate reusable authenticated web access to that catalog. If missing, propose the smallest adapter around existing domain services; validate its contract before implementation.
3. Build the tree with distinct catalog data, filter state, and current-template linked IDs. Derive Linked from links, not from cached flags on catalog nodes.
4. Wire search, regime selection, and All/Linked. Use existing client patterns to prevent an earlier response overwriting a later selection.
5. Test a small deterministic real-shape fixture and a persisted desktop template. Integrate link-change refresh with L2/L6; fixture-based coverage alone does not finish AC4.

### Open questions / held behavior
- Q-L1-1: On changing regime, does desktop retain, hide, invalidate, or remove existing links? Regime-change mutation behavior remains held; AC5 does not answer this case.
- Q-L1-2: Exact search matching: name/prompt/path, case sensitivity and parent-node retention. Read desktop logic before finalizing exact expected matches.
- Q-L1-3: Does Linked include links on every sheet and how does it represent variables no longer available in the catalog?

Risks: large catalogs, stale asynchronous results, confusing node identity with labels. Depends on shared catalog access and link representation; mutation integration depends on L2/L6.

## L2 — Create and persist economic variable links

Estimate O/P:40h /10SP.

### Proposed acceptance criteria — known scope
- AC1: For a valid writable target and eligible economic variable, the author can create a Summary or Periodic link using the accepted web interaction. A persisted domain association is created; inserting a snapshot value alone does not satisfy this AC.
- AC2: A created link displays inherited Variable Name, Prompt and Type read-only and uses desktop defaults for its remaining settings.
- AC3: After save, closing and freshly reopening the template preserves variable identity, link kind, worksheet/range association and the required metadata. Workbook named ranges and VariableList refer to the same link.
- AC4: A template with newly created links can be consumed by the existing report generator and matches an equivalent desktop fixture for the agreed representative cases.
- AC5: Failed validation or a rejected save does not leave a successfully persisted workbook with missing/mismatched link metadata. Existing template data remains recoverable through the shared save contract.

### Implementation plan
1. Trace desktop link creation through editor/helper/entity code. Document identifier construction, range naming, Summary/Periodic distinction, default values and minimum persisted fields.
2. Implement an adapter from the chosen spreadsheet selection to the domain range representation. Keep control-specific coordinates separate from the domain model.
3. Reuse desktop/domain rules to create the link and corresponding workbook named range; validate variable eligibility and target before mutation.
4. Integrate both changes with the shared lock-aware save operation. Define a consistent failure path; do not independently save workbook and link list from unrelated UI requests.
5. Add create→save→fresh reopen→generate regression cases for Summary and Periodic links. Cover representative Standard and OLS behavior through confirmed fixtures.

### Open questions / held behavior
- Q-L2-1: What counts as a valid target: merged/protected cells, non-contiguous selections, existing linked cells, multi-cell Summary links?
- Q-L2-2: For overlapping targets, does desktop replace, split, reject or combine links? Overlap mutation is held until verified.
- Q-L2-3: What interaction is approved: drop, selection+Link, or both? Desktop semantics are fixed; web gesture choice is not established by this plan.

Risks: orphaned named ranges; corrupt range/metadata association; component reload losing unsaved edits. Depends on L1 and shared host/save. L2 owns initial link creation; L6 owns subsequent structural edits and unlink.

## L3 — Link report metadata variables

Estimate O/P:32h /8SP.

### Proposed acceptance criteria — known scope
- AC1: Confirmed metadata leaves can be linked using the same persistent mechanism as economic variables: Project Settings/Dates, Calculation Settings, Report Options, Comments, Discount Date/Method and Incremental Project Info.
- AC2: Each metadata link preserves its domain identity and desktop-defined type after save/reopen. Comments is a linkable value, not merely a category label.
- AC3: Metadata appears in the shared tree for Standard and One Line Summary templates according to the confirmed desktop eligibility matrix.
- AC4: Existing generator output for representative metadata links matches the corresponding desktop fixture; no new hierarchy configuration or calculation behavior is introduced.

### Implementation plan
1. Map each required category/leaf from ADO1869322 to desktop definitions and its existing pseudo-variable provider. Record unsupported or unclear mappings instead of substituting similarly named fields.
2. Reuse L2 creation/persistence while preserving pseudo-variable identity and type; avoid duplicating linking code for each category.
3. Apply existing pseudo-variable eligibility rules. Expose read-only metadata; editable settings are owned by L4.
4. Add fixture-based roundtrip and generator checks across the supported categories and both template types.

### Open questions / held behavior
- Q-L3-1: Confirm behavior of unavailable context, absent incremental settings, and missing metadata values from desktop/provider tests.
- Q-L3-2: Identify any category/leaf whose ADO wording does not uniquely map to a domain definition; hold that leaf until resolved.

Scope boundary: comparison-run metadata belongs to L5. Discount Rate slots belong to1869369; Date/Formula Range belongs to1869339. Risks: incorrect provider mapping and inappropriate property availability. Depends on L2.

## L4 — Configure variable link attributes and headers

Estimate O/P:32h /8SP.

### Proposed acceptance criteria — known scope
- AC1: Selecting one existing link displays its current settings. Name, Prompt and Variable Type remain inherited/read-only.
- AC2: An eligible link supports editing Working Interest, Real/Nominal, Type, Discount Rate selection and Show Header/Above/Left without recreating the link.
- AC3: Enabled/disabled or visible states and accepted combinations match the verified desktop settings matrix. At the inspected baseline, WI excludes pseudo-links, Real/Nominal depends on currency units, and DiscountRate applies to supported periodic numeric modes; revalidate the complete matrix before coding.
- AC4: Save/reopen preserves the edited settings and the association to the same variable/range. Existing generator output and header placement match the agreed desktop fixtures.
- AC5: Settings disallowed by the domain rules cannot be persisted by bypassing the UI.

### Implementation plan
1. Extract an attribute matrix from ReportVariableLinkSettingsViewModel and corresponding domain/generator code: eligibility, allowed values, defaults and interactions. Keep unresolved cells marked unknown.
2. Implement selection→link→properties-panel mapping, using one source of truth for displayed values and edit state.
3. Reuse domain validation in the save/update path; mirror relevant constraints in the UI for feedback.
4. Update existing link settings and header layout through the workbook adapter without rebuilding unrelated links.
5. Test representative variable-type/mode combinations, readonly fields, save/reopen and header layout.

### Open questions / held behavior
- Q-L4-1: Does changing Type clear, preserve or reset incompatible settings? Determine exact desktop transitions before implementing them.
- Q-L4-2: How does changing header placement affect existing cell content or neighboring links? Hold destructive/collision cases until verified.
- Q-L4-3: Properties behavior when the selection contains multiple different links is unconfirmed; single-link AC does not decide bulk editing.

Risks: invalid combinations and overwritten headers. Depends on L2/L3. Placeholder Run is L5; slot-value behavior is1869369. Shared ribbon styling is outside this story; link header placement is inside.

## L5 — Configure run-specific links and comparison metadata

Estimate O/P:32h /8SP.

### Proposed acceptance criteria — known scope
- AC1: Eligible links expose Placeholder Run according to desktop rules; ineligible links do not accept unsupported assignments.
- AC2: Changing Placeholder Run updates the existing link and preserves the assignment after save/reopen.
- AC3: Comparison Calculation Settings leaves use their proper domain identities and persist through the common linking mechanism.
- AC4: For an agreed existing multi-run fixture, generated output resolves each configured link against the intended run and displays corresponding comparison metadata, matching desktop output.
- AC5: The story does not introduce a new execution screen, new sensitivity calculation or hierarchy-level incremental configuration.

### Implementation plan
1. Trace desktop eligibility, persisted run identifiers and generator resolution for business and pseudo-variables. Distinguish display labels from stable run-slot identifiers.
2. Implement the eligible-run property control and validate assignments using existing domain rules.
3. Add comparison metadata definitions/providers to L3's mapping mechanism without changing the report-execution contract.
4. Add two-run fixtures with distinct values/context so a swapped or defaulted run assignment cannot pass unnoticed. Verify save/reopen before generation.

### Open questions / held behavior
- Q-L5-1: Default selection and handling of missing/unavailable run context are not yet established.
- Q-L5-2: Confirm behavior when a comparison field is linked but only one run is supplied; do not invent fallback values.

Risks: wrong-run resolution and unintentional expansion into execution. Depends on L2/L3 and access to an existing multi-run generation fixture.

## L6 — Manage links and preserve them during spreadsheet edits

Estimate O/P:32h /8SP, conditional on a bounded confirmed edit matrix. Re-estimate/split when the matrix is known; this estimate is not a promise to implement unrestricted Excel editing.

### Proposed acceptance criteria — known scope
- AC1: Selecting a single existing linked range resolves its persisted association for inspection. Unlink removes the association and updates the Linked filter; effects on workbook content must follow the confirmed desktop rule, not an assumed clearing policy.
- AC2: After unlink/save/reopen, no stale link record or link-owned named range remains according to the desktop cleanup contract.
- AC3: For EACH structural-edit scenario accepted into the matrix below, perform the edit, save, fresh reopen and report generation; resulting range associations and values match the desktop reference. This AC is conditional and cannot be signed off before the matrix is resolved.
- AC4: An edit failure must not silently persist mismatched workbook/link metadata. Unsupported operations require an explicitly approved handling policy; rejection is not assumed to be acceptable desktop parity.

### Implementation plan
1. Build a scenario matrix from desktop commands/helper code and actual fixtures: insert/delete rows/columns, copy/cut/paste linked ranges, moving/rebinding ranges, sheet rename/delete and overlapping/mixed selections. For each record expected workbook, named ranges, link metadata and generator result.
2. Mark each scenario confirmed/unknown plus source revision. Determine what the chosen component does automatically and where a domain adapter is required.
3. Implement single-link lookup and unlink using the confirmed cleanup semantics; connect changes to L1 refresh and the shared save unit.
4. Implement ONLY confirmed structural-edit behavior in the agreed scope. Preserve link identifiers or regenerate them according to evidence; do not blindly clone metadata on paste.
5. Add before/edit/save/reopen/generate regression fixtures per confirmed scenario. Split scenarios into additional PBIs if complexity exceeds8SP rather than silently dropping desktop behavior.

### Open questions / held behavior
- Q-L6-1: Does unlink preserve cell values, formulas, formatting and headers? What named-range cleanup is required?
- Q-L6-2: Exact behavior for copy versus move, overlapping links, multi-link selections, deleting linked rows and deleting/renaming sheets.
- Q-L6-3: Can a link's Range be edited directly without recreation? What validations/side effects apply?
- Q-L6-4: Which operations can be delivered in this8SP slice, and how are remaining desktop scenarios decomposed? This affects scope/estimate, not permission to invent new behavior.

Risks: orphaned metadata, duplicate link identities, subtle engine-specific coordinate changes. Depends on L2 and shared editor mutation/save infrastructure. Integration with L4/L5 must preserve all settings during edits.

## Delivery and ownership notes

These are proposed replacement PBIs for1869322, with local labels L1–L6 rather than real ADO IDs. No ADO items have been created. Retain traceability to1869322; avoid counting the original50SP again after estimates move to the six stories.

Every slice includes its own meaningful tests and QA. Shared final migration/ribbon/security/deployment work stays in the Feature estimate; do not double-count it. L1 can begin with existing-template fixtures, L2 establishes mutations, L3/L4/L5 extend the domain, L6 handles lifecycle/structural edits. Implementation starts only after the relevant shared prerequisite exists. Questions are a work list for source-based verification, not already-approved acceptance criteria.
