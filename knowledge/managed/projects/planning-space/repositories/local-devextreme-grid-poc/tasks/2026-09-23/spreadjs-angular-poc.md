# SpreadJS Angular variable-workbook POC

## Verified result

The `local-devextreme-grid-poc` repository contains the separately runnable `spreadjs-angular-poc` comparison application. At commit `6a832183d93fd69452e16dfd7cb228d06f17601b`, it uses Angular 20.3 and the official MESCIUS SpreadJS 19.2.3 core, Angular, IO, and Designer package family in evaluation mode; no license key is stored.

The POC keeps one native workbook instance shared by the typed variable palette, the official Designer ribbon, and a separately visible original Angular formatting toolbar. The toolbar supports the current native selection for font, color, alignment, wrapping, number formats, borders, merge/unmerge, and clear-formatting operations. Existing variable drops, undo/redo, protection behavior, and XLSX import/export remain present. Pending XLSX import remains exclusive: UI and component entry points reject mutation, export, and drag/drop until the import settles.

## Verification and scope

Final validation at that commit passed 35 of 35 Vitest tests, the Angular production build, and 1 of 1 Microsoft Edge scenario covering both formatting paths, XLSX reopen persistence checks, and variable-drop regressions. Reviewer artifact `05efc582077e5ac21803c8d539525cb64e4f5616fc2c9090729a162d983c6771` and independent verification artifact `328f38200e54a3ebeb146f6679f7a2accba374f1d94aa82948ab91ea94a5a50b` are bound to that revision. The user rejected REV-003 and REV-004 as sufficient for this proof of concept; they are not implemented changes or engineering standards.

This is repository-scoped comparison-POC knowledge. It does not establish a global coding standard or a production workbook-integration contract. Evaluation licensing, official-package CommonJS bundle warnings, eight moderate transitive dependency findings, client-side limits, production-scale performance, accessibility conformance, advanced Excel fidelity, and unsupported workbook features remain outside the verified POC scope.
