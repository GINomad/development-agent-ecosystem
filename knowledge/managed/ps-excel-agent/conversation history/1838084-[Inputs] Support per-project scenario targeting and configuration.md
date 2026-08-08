# [Inputs] Support per-project scenario targeting and configuration

## Ticket
1838084 - [Inputs] Support per-project scenario targeting and configuration

## Context
Investigation into how `ProjectScenarioName` / scenario configuration currently flows through the `ps-app-delfi` integration, in order to support **per-project** scenario targeting and configuration instead of a single scenario applied uniformly to every project in a calculation request.

This builds on the earlier investigation in
[`1813945-Define scenario for projects and variables.md`](./1813945-Define%20scenario%20for%20projects%20and%20variables.md), which documented the *current* (global, single-scenario) behavior.

---

## Current Behavior (as of this investigation)

### Single scenario per request, not per project

**File:** `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\CalculationInputConverter.cs`

`ConvertToPSFormat` builds **one** `ProjectSettingsModel` (`psSettings`) and **one** `ScenarioModel` (`psScenario`) from the single `InputVariablesSpecification spec` argument:

```csharp
var psSettings = new ProjectSettingsModel()
{
	ApplyWorkingInterestToAllScenarios = spec.ApplyWorkingInterestToAllScenarios,
	ChosenScalarConversionDate = startDate,
	InheritWorkingInterest = spec.InheritWorkingInterest,
	Duration = (short?)yearDates.Count,
	InflationDate = inflationDate,
	IsDefaultScenarioFailure = spec.IsDefaultScenarioFailure,
	ProjectScenarioName = spec.ProjectScenarioName,
	ScalarConversionOption = EnumFromString<ScalarConversionDateOption>(spec.ScalarConversionOption),
	PeriodicDataTransformationStrategy = EnumFromString<StartYearChangeOption>(strategy),
	StartYear = (short?)startDate?.Year
};

var psScenario = new ScenarioModel()
{
	Name = spec.ProjectScenarioName,
	IsEconomicLimitCalculated = true,
	MinimumMonthsToEvaluate = 12,
	Weighting = 100,
};

List<ScenarioModel> psScenarios = new() { psScenario };
```

These are then applied identically to **every** project produced by the per-schema converters, via the grouping step at the end of the method:

```csharp
var groupedProjects = projects.GroupBy(x => x.Name.ToUpper())
	.Select(x => new AgentProjectCreationModel
	{
		Name = x.Key,
		ParentId = 0,
		Scenarios = psScenarios,     // ← same scenario list for all projects
		Settings = psSettings,       // ← same settings for all projects
		WorkingInterestSettings = null,
		Variables = x.SelectMany(v => v.Variables).Concat(referenceDatesVariables).ToList()
	}).ToList();
```

There is currently **no mechanism** for a project (grouped by `Name`) to be assigned a *different* `ProjectScenarioName`, `ApplyWorkingInterestToAllScenarios`, `InheritWorkingInterest`, `IsDefaultScenarioFailure`, `ScalarConversionOption`, or `PeriodicDataTransformationStrategy` than any other project in the same request.

### Source of the single scenario/spec

**File:** `PlanningSpace.Integration.Delfi.Conversions\Models\EconomicsMappingModel.cs`

```csharp
public class InputVariablesSpecification
{
	public bool ApplyWorkingInterestToAllScenarios { get; set; }
	public bool InheritWorkingInterest { get; set; }
	public bool IsDefaultScenarioFailure { get; set; }
	public string ProjectScenarioName { get; set; }
	public string ScalarConversionOption { get; set; }
	public string PeriodicDataTransformationStrategy { get; set; }
	public IEnumerable<InputVariableMappingModel> Variables { get; set; }
	public IEnumerable<InputUnitConversion> UnitConversion { get; set; }
}
```

`InputVariables` is a single object in the economics mapping `.jsonc` file (see
`documentation\mapping files\Economics mapping file template.jsonc`, lines ~83-98), i.e. one set of scenario/settings values for the entire mapping file, not per-project.

### Propagation path

1. **Mapping file** (`.jsonc`) → `InputVariablesSpecification.ProjectScenarioName` (one value for the whole file).
2. **`DataTransformer.cs`** copies `variableMappings.InputVariables.ProjectScenarioName` into `CalculationInputModel.ProjectScenarioName`.
3. **`CalculationInputConverter.ConvertToPSFormat`** turns that single value into one shared `ScenarioModel`/`ProjectSettingsModel` applied to all grouped projects (see above).
4. **`CalculationController.cs`** (`PlanningSpace.Integration.Delfi.CalculationOrchestrator`) also carries a single `ProjectScenarioName` / `PriceScenarioName` pair on `CalculationInputModel`, used both for the "traditional" calculation payload and the Result Sets payload (lines ~135-145 and ~167-194), again applied uniformly across the whole hierarchy/run rather than per project.

### Per-variable `ScenarioName` already exists, but is unrelated to project targeting

Each entry in `InputVariablesSpecification.Variables` (`InputVariableMappingModel`) already carries its own `ScenarioName` (see many examples in `CalculationInputConverterTests.cs`, `ProductionResultConverterTest.cs`). This lets *variables* be tagged with a scenario name during conversion, but it does not let the *project itself* (settings/scenario metadata sent to Planning Space) be configured per project — it only affects how a variable's data is bucketed once inside a project/scenario that has already been fixed.

---

## Gaps Relative to the Requested Feature

1. **No per-project scenario configuration model.** `InputVariablesSpecification` and `CalculationInputModel` model a single scenario/settings tuple for an entire request; there is no keyed structure (e.g. by project name/FDPlan schema/hierarchy id) to hold different `ProjectScenarioName`/settings per project.
2. **`CalculationInputConverter.ConvertToPSFormat` applies `psSettings`/`psScenarios` uniformly** in the final `groupedProjects` projection — this is the central place that would need to look up project-specific configuration instead of closing over one shared `spec`.
3. **Mapping file schema has no per-project section.** The `.jsonc` template only exposes one `InputVariables` block; supporting per-project targeting will likely require either:
   - a new keyed collection (e.g. `ProjectScenarioOverrides: { "<ProjectName>": { ProjectScenarioName, ... } }`), or
   - moving scenario/settings under each FDPlan schema/converter definition.
4. **Orchestrator side (`CalculationController.cs`) also assumes one scenario per calculation/result-set run.** If "per-project" needs to propagate all the way to Planning Space execution (not just conversion), the Result Sets payload construction (which iterates hierarchy/projects) would need to select per-project scenario names rather than reusing `model.InputData.ProjectScenarioName` everywhere.

---

## Relevant Files for Implementation

| File | Role |
|---|---|
| `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\CalculationInputConverter.cs` | Builds `ProjectSettingsModel`/`ScenarioModel` and assigns them to grouped projects; central point to make scenario assignment per-project. |
| `PlanningSpace.Integration.Delfi.Conversions\Models\EconomicsMappingModel.cs` | Defines `InputVariablesSpecification` (single scenario/settings spec) and `InputVariableMappingModel` (per-variable `ScenarioName`). Needs a per-project extension. |
| `documentation\mapping files\Economics mapping file template.jsonc` | Documents the mapping file schema; would need new per-project section documented. |
| `PlanningSpace.Integration.Delfi.Agent\DataTransformer.cs` | Copies mapping file values into `CalculationInputModel`; needs to carry per-project overrides forward. |
| `PlanningSpace.Integration.Delfi.CalculationOrchestrator\CalculationController.cs` | Consumes `ProjectScenarioName`/`PriceScenarioName` when building calculation and Result Sets payloads; needs per-project scenario lookup when iterating projects/hierarchy. |
| `PlanningSpace.Integration.Delfi.ConversionsTests\CalculationInputConverterTests.cs` | Existing tests assert single shared `ProjectScenarioName = "Base"` across all projects; will need new tests for per-project overrides. |

---

## Open Questions

- How should a "project" be identified for targeting purposes — by the grouped `Name` (post-`GroupBy(x => x.Name.ToUpper())`), by FDPlan schema, or by an explicit project key in the mapping file?
- Should per-project overrides apply only to `ProjectScenarioName`, or also to the other `ProjectSettingsModel` fields (`ApplyWorkingInterestToAllScenarios`, `InheritWorkingInterest`, `IsDefaultScenarioFailure`, `ScalarConversionOption`, `PeriodicDataTransformationStrategy`)?
- Is a fallback/default scenario still required for projects without an explicit override?
- Does this need to also propagate to `CalculationController.cs` (Planning Space execution side), or is scope limited to the FDPlan → Economics conversion step?
---

## Deferred EMV / EV Investigation and Removed Prototype (2026-07-21)

### Current status

Special EMV handling was prototyped and then deliberately removed from `ps-excel-agent`. EMV/EV will be implemented separately later.

The current code should be treated as having no reserved EMV calculation mode:

- there is no EMV constant or special conditional branch;
- there is no conversion from EMV to an empty scenario;
- there is no EMV-specific validation error;
- there is no EMV-specific test;
- named-scenario and row-level scenario support remains in place.

### Confirmed domain knowledge retained for the future story

- EMV means Expected Monetary Value and is also described as EV.
- EMV is a calculation mode over all configured project scenarios, not a project scenario named `EMV`.
- Each scenario has a weighting. Mathematically, applicable scenario weights total `1.00`.
- The current PSE/SDK `ScenarioModel.Weighting` contract uses percentage values, so `100` represents `1.00` and `65` represents `0.65`.
- A future EV implementation should use all applicable project scenarios and their weighted results.

### Prototype behavior that was tried and removed

The removed prototype used this mapping when the general Project Scenario was EMV:

| Payload location | Prototype value |
|---|---|
| Calculation input `ProjectScenarioName` | empty string |
| Project settings `ProjectScenarioName` | empty string |
| Tagged Variable `ScenarioName` | scenario from the row's final `<ScenarioName>` path node |
| Untagged Variable `ScenarioName` | empty string |
| Project `Scenarios` collection | configured/tagged named scenarios only; no scenario named `EMV` |

The prototype had a unit test confirming the generated payload shape. It did not receive end-to-end confirmation from a live PSE calculation before removal.

### Non-EMV behavior that remains implemented

The general Project Scenario controls the named calculation context. A final `<ScenarioName>` node in an Excel Variables row controls the `ScenarioName` assigned to that variable override.

| Variable row scenario tag | General Project Scenario | Calculation/project settings scenario | Variable `ScenarioName` |
|---|---|---|---|
| none | named | general scenario | general scenario |
| none | blank | `Base` | `Base` |
| present | named | general scenario | row tag |
| present | blank | `Base` | row tag |

Tagged variable rows are forwarded with their resolved row scenario rather than being discarded merely because the tag differs from the general named scenario.

The implementation remains centered on:

- `ScenarioPathParser` for final-node `<ScenarioName>` parsing;
- `ExcelInputRowHelper` and `ResolvedExcelInputRow` for row-level scenario resolution;
- `ScenarioHelper` for default `Base`, Scenario Configuration validation/defaults, and scenario collection construction;
- `CalculationManager.CreateVariablesForProject` for scalar and time-series `ScenarioName` mapping.

### Scenario Configuration defaults retained

| Excel value | SDK field | Blank/default behavior |
|---|---|---|
| Weighting | `Weighting` | `100` |
| Group / consolidation group | `ConsolidationGroup` | blank/null |
| Calculate Economics Limit | `IsEconomicLimitCalculated` | `true` |
| Is Failure Scenario | `IsFailureScenario` | `false` |
| Min Months to Evaluate | `MinimumMonthsToEvaluate` | `12` |
| Specified Date | `EconomicLimitDate` | blank/null |

Aggregate weighting validation is not currently implemented.

### Important existing-project limitation

`PlanningSpace.Integration.Delfi.CalculationOrchestrator.ProjectsController.PatchProjects` replaces the complete project `settings`, `scenarios`, and `variables` values. An agent payload containing only a subset of an existing PSE project's scenarios can therefore overwrite scenarios that were not supplied.

Preserving untouched PSE scenario configuration requires either reading and merging the existing complete scenario list before replace or changing orchestrator patch semantics.

### Questions to resolve before reintroducing EMV

1. Confirm the calculation contract and explicit signal for EV mode.
2. Confirm whether project settings scenario should be blank or retain a real default named scenario.
3. Confirm how untagged Variables must be represented so they apply to all scenarios.
4. Decide where to validate that applicable weights total 100%.
5. Resolve existing-project scenario merge behavior before relying on complete multi-scenario payloads.
6. Add end-to-end PSE coverage before treating the behavior as supported.
---

## DataType Discriminator Removed for Separate Ranges (2026-07-23)

### Decision

Remove the Excel row `DataType` discriminator from the implementation.

The calculation request already carries two structurally distinct collections:

- `inputData: ExcelTableRowModel[]` for project variable overrides;
- `scenarioConfiguration: ExcelScenarioConfigurationRowModel[]` for scenario metadata and weighting configuration.

They originate from separate custom-function ranges, use different column layouts, and deserialize into different C# models. The collection/property type therefore identifies the row kind without a string discriminator.

Keeping `DataType` produced a hybrid design: separate typed collections plus discriminator-based parsing. It also required layout-detection heuristics in `functions.ts` and duplicated type information in TypeScript and C# DTOs.

### Resulting range layouts

Input Variables range:

1. Project path, optionally ending in `<ScenarioName>`
2. Variable alias
3. Unit
4. Real/Nominal
5. Period values

Scenario Configuration range:

1. Project path ending in `<ScenarioName>`
2. Weighting
3. Consolidation group
4. Calculate Economics Limit
5. Is Failure Scenario
6. Min Months to Evaluate
7. Specified Date

### Implementation impact

Removed:

- `DataType` from `ExcelTableRowModel` and `ExcelScenarioConfigurationRowModel` in C# and TypeScript;
- `InputVariableDataType`, `ScenarioWeightingDataType`, `INPUT_VARIABLE_DATA_TYPE`, and `SCENARIO_WEIGHTING_DATA_TYPE` constants;
- DataType validation and the unrecognised-DataType unit test;
- typed/untyped Input layout detection (`hasRecognizedDataType`, `hasShiftedProjectPath`, and `hasTypedInputLayout`);
- the leading DataType column from both range mappings.

### Requirements note

REQ-XLEAAS-022, REQ-XLEAAS-023, and AC3 describe `DataType` values because they assume discriminator-based rows. That wording conflicts with the separate Scenario Configuration range/parameter described by AC9 and used by the implementation. The acceptance criteria should be updated to reflect model/range-based discrimination if the separate-range design is retained.
---

## Scenario Configuration Scope: Global Assumption and Per-Project Fallback (2026-07-23)

### Current provisional assumption

Until product behavior is confirmed, assume the Scenario Configuration list is shared by every project participating in the Excel calculation.

Implementation status as of 2026-07-23: the agent and custom-function payload now implement this assumption. Scenario Configuration rows use `ScenarioName` instead of `Path`, and each configured scenario is included when building every project in the calculation.

Under this design:

- project identity exists only in Input Variable paths;
- a final `<ScenarioName>` node in an Input path selects the variable scenario;
- an untagged Input path resolves to the Project Scenario from Settings, with `Base` as the default when Settings is blank;
- Scenario Configuration identifies a scenario by an explicit `ScenarioName`, not by a project path;
- the same configured scenario values are used when constructing that scenario for each project.

The intended global row model is:

```csharp
public class ExcelScenarioConfigurationRowModel
{
    public required string ScenarioName { get; set; }
    public double? Weighting { get; set; }
    public string? ConsolidationGroup { get; set; }
    public bool? CalculateEconomicsLimit { get; set; }
    public bool? IsFailureScenario { get; set; }
    public short? MinimumMonthsToEvaluate { get; set; }
    public DateTime? SpecifiedDate { get; set; }
}
```

This is a provisional design direction only. It has not yet been confirmed that projects cannot have different configuration for scenarios with the same name.

### Fallback if per-project configuration is required

If product clarification later confirms that `Base`, `High`, or another identically named scenario can have different weighting/configuration for different projects, restore project targeting explicitly rather than overloading one combined `Path` field.

Preferred future-compatible model:

```csharp
public class ExcelScenarioConfigurationRowModel
{
    public string? ProjectPath { get; set; }
    public required string ScenarioName { get; set; }
    // configuration fields
}
```

Semantics:

- `ProjectPath == null/blank` means a global scenario configuration applicable to every project.
- A populated `ProjectPath` means a project-specific configuration for `(ProjectPath, ScenarioName)`.
- A project-specific row overrides the global row with the same `ScenarioName` for that project.
- Blank fields within the selected project-specific row use the standard defaults unless product requirements explicitly define inheritance from the global row.
- Duplicate global keys `(ScenarioName)` and duplicate project-specific keys `(ProjectPath, ScenarioName)` must return descriptive errors.

Recommended precedence when constructing project scenarios:

1. Project-specific `(ProjectPath, ScenarioName)` configuration.
2. Global `ScenarioName` configuration.
3. Default values: Weighting 100, Calculate Economics Limit true, Is Failure Scenario false, Min Months 12, blank date/group.

Required range extension for that fallback:

```text
Project Path (optional), Scenario Name, Weighting, Consolidation Group,
Calculate Economics Limit, Is Failure Scenario, Min Months, Specified Date
```

Required code touchpoints:

- add optional `ProjectPath` to the C# and TypeScript Scenario Configuration models;
- update `functions.ts` range indexes;
- update `ScenarioHelper.ValidateConfiguration` duplicate-key validation;
- update `ScenarioHelper.CreateScenariosForProject` to select project-specific rows before global rows;
- add tests for global reuse, project-specific override, duplicate keys, and fallback to defaults.

Input row scenario resolution does not change between the global and per-project designs.
