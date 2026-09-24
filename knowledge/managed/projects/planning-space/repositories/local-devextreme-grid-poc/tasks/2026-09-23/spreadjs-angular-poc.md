# SpreadJS Angular variable-workbook POC

## Verified result

The `local-devextreme-grid-poc` repository contains the separately runnable `spreadjs-angular-poc` comparison application. At commit `6a832183d93fd69452e16dfd7cb228d06f17601b`, it uses Angular 20.3 and the official MESCIUS SpreadJS 19.2.3 core, Angular, IO, and Designer package family in evaluation mode; no license key is stored.

The POC keeps one native workbook instance shared by the typed variable palette, the official Designer ribbon, and a separately visible original Angular formatting toolbar. The toolbar supports the current native selection for font, color, alignment, wrapping, number formats, borders, merge/unmerge, and clear-formatting operations. Existing variable drops, undo/redo, protection behavior, and XLSX import/export remain present. Pending XLSX import remains exclusive: UI and component entry points reject mutation, export, and drag/drop until the import settles.

## Verification and scope

Final validation at that commit passed 35 of 35 Vitest tests, the Angular production build, and 1 of 1 Microsoft Edge scenario covering both formatting paths, XLSX reopen persistence checks, and variable-drop regressions. Reviewer artifact `05efc582077e5ac21803c8d539525cb64e4f5616fc2c9090729a162d983c6771` and independent verification artifact `328f38200e54a3ebeb146f6679f7a2accba374f1d94aa82948ab91ea94a5a50b` are bound to that revision. The user rejected REV-003 and REV-004 as sufficient for this proof of concept; they are not implemented changes or engineering standards.

This is repository-scoped comparison-POC knowledge. It does not establish a global coding standard or a production workbook-integration contract. Evaluation licensing, official-package CommonJS bundle warnings, eight moderate transitive dependency findings, client-side limits, production-scale performance, accessibility conformance, advanced Excel fidelity, and unsupported workbook features remain outside the verified POC scope.

## Revision 3: Angular formula and standard-chart authoring

At local commit `a2548add2e3a5c5b071cb3bbf849802606a1b667`, the POC adds an Angular-owned formula and standard-SpreadJS-Charts workflow without depending on the Designer Ribbon. The formula bar follows the active cell and commits through public undoable APIs. Its bounded function catalog contains `IF`, `SUM`, `AVERAGE`, `MAX`, and `MIN`; native worksheet selection inserts A1 references, retaining an explicit captured token so a second capture can intentionally replace it while a caret move selects a new insertion position.

The Angular chart gallery creates clustered-column, line-with-markers, clustered-bar, and pie charts from valid tabular selections. The selected-chart panel changes title, legend, value labels, applicable axes, first-series color, and geometry; invalid geometry leaves the workbook unchanged and reports a validation message. Formula commits, chart creation, and chart-property changes participate in workbook undo/redo. The tested XLSX roundtrip retains a representative SUM formula and clustered-column chart with representative properties.

Validation at this revision passed 50/50 Vitest tests, the production Angular build (27.82 MB initial bundle, below its 28 MB error budget), and 1/1 Microsoft Edge scenario. Reviewer artifact `54496daf6cb9b5003141263d26b67c35c7a7c068f00921ecec52c2f5cdfc6055` was clean; independent verification artifact `f6e7ed2a44c230077a06a0d03372e96b2c460c4cbc24955a2ef8bcd50f5dac65` passed for that exact revision. Designer remains optional and is not attached until the comparison toggle is selected; DataCharts is neither installed nor used.

This remains local comparison-POC evidence, not a production integration contract. The Designer packages still contribute to the evaluated bundle. Macros, external links, advanced charts, DataCharts, unsupported formulas, universal Excel fidelity, accessibility conformance, and production licensing/deployment are not established by this result.
