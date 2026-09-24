# Recommended delivery order — Feature1865781

Reviewed2026-09-24. Fresh ADO descriptions/AC/comments for Feature and all9 direct leaf stories; additionally reviewed predecessor1874388, related1869308 and their child definitions. No ADO or product code changes. Repository source was not re-audited this turn; desktop-code evidence remains the previously inspected baseline, to refresh before implementation.

## Current findings

All9 direct stories are New. Feature remains rev59 with stale live Discount Rate input wording and Formula Range uncertainty; desktop parity remains the user's accepted baseline.1869369 has a comment confirming parity output direction, but its description still describes cell input.1869334/1869339/1869369 still have no formal AC. Orientation's old reference to linking1869322 should now point to1877820;1869322 now only browses/filters.

Predecessor1874388 is New. Its child1874428 (Angular-compatible spreadsheet packages) is Develop;1874423 (Office add-in variable interaction) New;1878698 (Will IFrame be approved by Security?) New. Component/security decision is a real prerequisite; working POC alone is not a recorded approval. Office add-in interaction research is not automatically a blocker for an embedded web Spreadsheet once the architecture is agreed.

1869308 Report Management is Backlog in PI26.4. Its children1876572(browser),1876573(CRUD),1876576(permissions),1876574(master designation),1876575(XML import/export) are New. For editor integration agree template identity/open/create/save and permission contracts with1876572/1876573/1876576. Do not wait for every management feature to start editor work; do not ship by bypassing permissions. Core persistence/lock-aware editor hosting is still not assigned a dedicated story among1865781's9 children.

## Stage0 — foundation and early risk reduction

Resolve1874428+1878698 under1874388: component/host, Angular integration, required security controls and supported interaction. Reuse existing POC evidence instead of rerunning proven experiments. While decisions are pending, desktop semantics/catalog work and test-fixture preparation can proceed.

Define an owner/story for product editor shell and authenticated open/save with update permission, business lock, selection/range representation and atomic workbook+VariableList persistence. Demonstrate open an existing desktop template -> edit -> save -> close -> reopen without losing named ranges/links. Start representative migration corpus immediately; do not postpone compatibility discovery to release.

## Recommended order for one implementation stream

| Order | Work item | Why here / completion nuance |
|---|---|---|
|1|1869322 Browse and filter report variables|Build real catalog, identity, Regime/search/All-Linked. Begin with existing-template fixtures. Final create/remove refresh AC needs1877820/1877832 integration; do not mark complete on mocks alone.|
|2|1869334 Configure template time-series orientation|Persist template orientation before periodic-link behavior is built. Confirm/Clear regression can use existing desktop-template links, then rerun on web-created links. Can run alongside1869322.|
|3|1877820 Create and persist economic variable links|First end-to-end slice: select variable, create Summary/Periodic link, save, reopen, verify existing generator. Depends on shared host/save, catalog contract and orientation behavior.|
|4|1877832 Manage links and preserve them during spreadsheet edits|Start selection/unlink and structural-edit compatibility now to validate the persistence design early. Matrix remains unresolved; split/re-estimate if too large. Full preservation regression must be extended as later settings/run stories arrive; early implementation is not premature closure.|
|5|1877828 Link report metadata variables|Reuse the tested link mechanism for pseudo-variables and both report types; avoids duplicating persistence.|
|6|1869339 Support Range links|Date Range first, Formula Range second, following desktop generator. Depends on orientation and shared range/persistence contracts, not inherently on completion of metadata. Can run in parallel with1877828. The previous24SP estimate warrants separate sprint-sized stories rather than one commitment.|
|7|1877829 Configure variable link attributes and headers|Apply confirmed type/eligibility matrix across economic and metadata links. Range fixtures support periodic-output regression. Can begin after1877820; full closure requires metadata combinations.|
|8|1869369 Support Discount Rate links|Integrate desktop Rate1-5 outputs and link rate selection using stable pseudo-variable/property contracts. The selector in1877829 can be built earlier; it need not wait for every displayed Rate slot. Correct contradictory description/AC before committing; no new cell-input calculation engine in baseline.|
|9|1877830 Configure run-specific links and comparison metadata|Finish multi-run context after economic/metadata persistence and common property editing are stable. Needs1877820+1877828 and a two-run fixture; no hard dependency on Discount Rate or Formula Range, so can run in parallel once its prerequisites are ready.|

The table is a recommended risk-aware sequence, not nine mandatory finish-to-start dependency links. In particular All/Linked refresh and later-setting preservation create cross-story integration checks; they are not reasons for circular start blockers.

## Parallel tracks after common contracts stabilize

- Catalog1869322 and orientation1869334.
- After base link1877820:1877832 link lifecycle plus metadata1877828 or range1869339, with distinct adapters/files and agreed mutation contracts. Avoid competing rewrites of the same shared adapter.
- After metadata: settings1877829 and run context1877830 can progress in parallel if property ownership is clear; rates1869369 can follow/reuse the pseudo-variable mapping.
- Migration corpus, security controls and deployment readiness proceed throughout; final cross-feature regression follows all implemented link types.

## Feature completion gates

1865781 is the parent outcome, not an extra implementation task after its children. Close only once all accepted behavior plus AC10 migration and AC11 spreadsheet/ribbon parity have evidence, and integration with Report Management, security, deployment and required AIDLC work are complete. Missing foundation/migration/ribbon/delivery stories need owners before sprint commitments. Do not infer completion from9 child statuses alone.

Before scheduling: update outdated references and desktop-parity wording, write testable AC for orientation/ranges/rates, settle the bounded structural-edit matrix, split1869339 and any oversized residual scope. Fresh capacity, holidays and resource assignments were not reviewed; this recommendation is technical sequencing, not a calendar plan.

## First deliverable

After architecture/security decision and minimal host/save:1869322+1869334+1877820 should demonstrate selecting a real variable, linking it in the chosen orientation, saving and reopening the template, with compatible generator output. Implement1877832's initial unlink/structural tests immediately next. This proves the hardest shared contract before broad feature expansion.
