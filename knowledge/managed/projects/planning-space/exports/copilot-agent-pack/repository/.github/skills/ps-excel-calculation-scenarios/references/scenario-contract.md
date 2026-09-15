# Scenario and input-range contract

## Current intended model

Input Variables and Scenario Configuration arrive as separate ranges and separate collections:

- `ExcelInputModel.InputData` contains `ExcelTableRowModel` rows.
- `ExcelInputModel.ScenarioConfiguration` contains `ExcelScenarioConfigurationRowModel` rows.

Do not add a string `DataType` discriminator while these collections remain separate. The request structure already discriminates row types. Avoid typed/untyped column-shift heuristics in `functions.ts`.

Input Variables layout:

1. Project path, optionally ending in `<ScenarioName>`
2. Variable alias
3. Unit
4. Real/Nominal
5. Period values

Scenario Configuration currently identifies global configuration by `ScenarioName`, followed by weighting, consolidation group, economics-limit flag, failure flag, minimum months, and specified date. Confirm current TypeScript and C# indexes before editing.

## Resolution rules

- Blank general Project Scenario defaults to `Base`.
- A final `<ScenarioName>` path node selects `Variable.ScenarioName` for that row.
- Tagged rows retain their row scenario even when it differs from the general scenario.
- Untagged rows use the named/default general scenario.
- Apply the same resolution to scalar and time-series variables.

Default scenario configuration historically used:

- Weighting: `100`
- Consolidation group: blank/null
- Calculate economics limit: `true`
- Failure scenario: `false`
- Minimum months: `12`
- Specified date: blank/null

The global configuration scope was provisional. If product requirements later require per-project values for the same scenario name, add an explicit optional `ProjectPath` and use precedence:

1. project-specific `(ProjectPath, ScenarioName)`;
2. global `(ScenarioName)`;
3. defaults.

Validate duplicate global and project-specific keys independently.

## EMV / EV

EMV means Expected Monetary Value over configured project scenarios; it is not a scenario literally named `EMV`. A previous prototype was removed and was never confirmed end to end.

Do not add EMV-specific branches as part of named-scenario work. Before future implementation, confirm the explicit EV calculation signal, project-settings scenario, untagged-variable semantics, weight validation, and existing-project merge behavior.

## Existing-project overwrite risk

The shared orchestration path has historically replaced the complete `settings`, `scenarios`, and `variables` payload during project patching. Sending only a subset can remove omitted scenarios. Re-read the current package/source behavior and require a full read/merge or changed patch semantics before claiming preservation.
