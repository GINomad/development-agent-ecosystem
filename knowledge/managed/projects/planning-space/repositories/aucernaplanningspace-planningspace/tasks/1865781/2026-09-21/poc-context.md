# Verified historical POC context
Copied publications under poc-evidence/ concern completed local POCs, not completion of 1865781.
- Excel Angular add-in 3ec943a9a1fd658c05a9f41954244e208e676aa4: 16 tests; mock variables, range/context-menu insertion and GETVARIABLE function; native task-pane-to-grid drop rejected as unsupported. Desktop smoke not executed then.
- Double-click refinement ceecc01cb0fc4a32542d817154c4693289c3cfdb: 17 tests; single click selects, double click inserts once.
- DevExtreme/Spreadsheet fa96ce6dd400893bf3c14d30f46951f283024f17: verified final local publication; 37 frontend/17 .NET tests (implementation-result distinguishes earlier test revision from final README-only change), Release build, real Edge153 production XLSX roundtrip.
- DataGrid Angular20.3/TS5.8.3/DevExtreme24.1.7: first worksheet, 7 columns, 1000 rows/5MB. Formulas/multiple sheets/merged cells/protection/arbitrary styling roundtrip unsupported.
- Spreadsheet: server-rendered ASP.NET Core8/DevExpress24.2.5, not Angular-native. Value snapshots, no live business binding. Active-sheet writable targets, selection/pointer semantics, 10000-cell bound, protected-cell skips/counts. Reload after drop because client API lacks arbitrary multi-cell write.
- Upload10MB with package/XML validation; live SaveCopy download. Native B2 edit and C3=42 drop survived roundtrip. Only Edge153 verified. Pointer mapping uses synthetic activation/public selection/bounds: revalidate future versions.
- Production tenant auth, persistent business links, concurrency/multi-instance, migration and performance are not proven by POC. Cosmetic TD-REV-002 stays bypassed task-local debt.
Project knowledge imported from ps-excel-agent/ps-app-delfi is not main PlanningSpace evidence.
