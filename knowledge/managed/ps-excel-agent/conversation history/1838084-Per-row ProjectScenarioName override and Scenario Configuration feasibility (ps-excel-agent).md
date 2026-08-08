# 1838084 — Per-row ProjectScenarioName override & Scenario Configuration feasibility (ps-excel-agent)

## Context
Follow-up investigation to [`1838084-[Inputs] Support per-project scenario targeting and configuration.md`](./1838084-%5BInputs%5D%20Support%20per-project%20scenario%20targeting%20and%20configuration.md). That file covered `ps-app-delfi` (FDPlan → Economics path). This file covers the **actual target repo for the XLEAAS requirements**: `C:\Repos\ps-excel-agent` (Excel Add-in backend + custom functions), and confirms the shared code path with `ps-app-delfi`.

No code was changed during this investigation — planning/discovery only.

---

## 1. Repo mismatch clarified
The XLEAAS requirements (`PSECALCULATEANDWAIT`, Excel Inputs section, `<scenario>` path tag, DataType discriminator) belong to **`ps-excel-agent`**, not `ps-app-delfi`. Confirmed no such code exists in `ps-app-delfi` (`get_projects_in_solution` + targeted searches for `PSECALCULATEANDWAIT`/`DataType` discriminator/`<scenario>` parsing all came back empty).

`ps-excel-agent` structure:
- `planningspace.integration.excel.agent` — ASP.NET Core backend (Calculation manager, controllers).
- `planningspace.integration.excel.ui` — Office Add-in (custom functions, `functions.ts`).

---

## 2. Current state in `ps-excel-agent`

### Models
`Models\ExcelInputModel.cs`:
```csharp
public class ExcelInputModel
{
	public string? HierarchyName { get; set; }
	public string? PriceDeckName { get; set; }
	public string? PriceScenarioName { get; set; }
	public string? CurrencyDeckName { get; set; }
	public int? StartYear { get; set; }
	public string? Periodicity { get; set; }
	public string? Results { get; set; }
	public string? ProjectScenarioName { get; set; } // single, global value — e.g. "Base"
	public string[]? OutputVariableAliases { get; set; }
	public List<ExcelTableRowModel>? InputData { get; set; }
	public bool UseAdvancedCalculation { get; set; } = true;
	public bool SaveResults { get; set; } = false;
}
```

`Models\ExcelTableRowModel.cs` (used for both input rows and output rows):
```csharp
public class ExcelTableRowModel
{
	public required string Path { get; set; }         // e.g. "Corporate Rollup\USA\Texas\ProjectA"
	public required string VariableAlias { get; set; }
	public string? Unit { get; set; }
	public required string? RealNominal { get; set; }
	public required object?[] Values { get; set; }
}
```
No `ProjectScenarioName`, no `DataType` discriminator, no `<scenario>` tag parsing.

### Custom function signatures (`src\functions\functions.ts`)
- **`PSECALCULATION`** (column-based, ~line 233): fixed columns `Path | VariableAlias | Unit | RealNominal | Values...` (`inputData: usefulRows.map(row => ({ path: row[0], variableAlias: row[1], unit: row[2], realNominal: row[3], values: row.slice(4) }))`). Single global `projectScenario` parameter appended after `inputData`.
- **`PSECALCULATIONFROMJSON`** (~line 337): accepts a pre-built `ExcelInputModel` as JSON string — new fields added to the C# model are automatically available here with **zero signature changes**, since `JSON.parse`/`JsonSerializer` just populate whatever properties are present.

### Application of scenario — `CalculationManager.cs`
- `CreateVariablesForProject` (~936-995): every `TimeSeriesVariableDataModel`/`ScalarVariableDataModel` **already has a per-variable `ScenarioName` property** — currently always set to `data.ProjectScenarioName ?? "Base"` (global, not per-row).
- `GetExcelProjects` (~780-905): builds **one** `ScenarioModel` per project (`Name = data.ProjectScenarioName ?? "Base"`), applied identically to every unique `Path`.

**Conclusion:** the per-variable `ScenarioName` plumbing already exists structurally — only the *source* of the value needs to change from "always global" to "row override, falling back to global".

---

## 3. Feasibility: per-row `ProjectScenarioName` override (falls back to `ExcelInputModel.ProjectScenarioName`)

**Feasible, low-to-medium effort.** Required changes:

1. `ExcelTableRowModel.cs` — add `public string? ProjectScenarioName { get; set; }`.
2. `CalculationManager.CreateVariablesForProject` — change `ScenarioName = data.ProjectScenarioName ?? "Base"` to `ScenarioName = inputData.ProjectScenarioName ?? data.ProjectScenarioName ?? "Base"` (both TimeSeries and Scalar branches).
3. `CalculationManager.GetExcelProjects` — replace the single fixed `ScenarioModel` with one entry per **distinct** scenario name actually used by that project's rows:
```csharp
var scenarioNames = data.InputData.Where(d => d.Path == path)
	.Select(d => d.ProjectScenarioName ?? data.ProjectScenarioName ?? "Base")
	.Distinct();
[Scenarios] = scenarioNames.Select(name => new ScenarioModel { Name = name, IsEconomicLimitCalculated = true, MinimumMonthsToEvaluate = 12, Weighting = 100 }).ToList()
```
4. Function signatures:
   - `PSECALCULATIONFROMJSON` — no change needed (JSON already flows through).
   - `PSECALCULATION` (column-based) — adding a positional column is a **breaking change** (shifts `Values = row.slice(4)`). Safer alternative: rely on the `<scenario>` tag embedded in `Path` (per REQ-021) instead of a dedicated column, avoiding any column-layout change.

---

## 4. Scenario Configuration sub-section (REQ-023) — SDK field mapping

The object actually sent to PSE is `Aucerna.Calculation.Advanced.Models.ScenarioModel` (NuGet `Aucerna.Calculation.Advanced`, v20.4.18.1), used identically by `ps-app-delfi` (`CalculationInputConverter.cs`, `ProjectsController.cs`) and `ps-excel-agent` (`CalculationManager.GetExcelProjects`) — confirmed via Go-To-Definition/decompiled source:

```csharp
public class ScenarioModel
{
	public const int DefaultMinimumMonthsToEvaluate = 12;
	public int Id { get; set; }
	[Key][Required][MaxLength(50)] public string Name { get; set; }
	[MaxLength(50)] public string ConsolidationGroup { get; set; }
	public DateTime? EconomicLimitDate { get; set; }
	public bool? IsEconomicLimitCalculated { get; set; } = true;
	public bool? IsFailureScenario { get; set; }
	public short? MinimumMonthsToEvaluate { get; set; } = (short)12;
	public double Weighting { get; set; }
}
```

| REQ-023 field | SDK property | Notes |
|---|---|---|
| Weighting | `Weighting` (double) | SDK default `0`, requirement default `100` → must set explicitly |
| Calculate Economics Limit | `IsEconomicLimitCalculated` (bool?) | SDK default `true` — matches |
| Is Failure Scenario | `IsFailureScenario` (bool?) | SDK default `null` — must explicitly default to `false` |
| Min Months to Evaluate | `MinimumMonthsToEvaluate` (short?) | SDK default `12` — matches |
| Specified Date | `EconomicLimitDate` (DateTime?) | maps 1:1, default `null`/blank — matches |
| **Group Weighting** | **not present anywhere** | Confirmed absent from `ScenarioModel`, `ProjectSettingsModel`, and the advanced-calc `ProjectCreationModel`. No mention anywhere in `ps-excel-agent` either. **Deferred per user decision (2024 session) — out of scope for now.** |

`ProjectSettingsModel` (same SDK) also confirmed via decompilation — has `ProjectScenarioName`, `ApplyWorkingInterestToAllScenarios`, `InheritWorkingInterest`, `IsDefaultScenarioFailure`, `ScalarConversionOption`, `PeriodicDataTransformationStrategy`, `StartYear`, `Duration`, `InflationDate`, `ChosenScalarConversionDate`, `CompanyName`, `DefaultPriceScenario` — no group-weighting-related field either.

**Decision:** Group Weighting is out of scope for this iteration. All new Scenario Configuration values should extend the existing row-data model (`ExcelTableRowModel` or a sibling model), not require new SDK/PSE API capability beyond what's already exposed by `ScenarioModel`.

---

## 5. CRITICAL DISCOVERY: `ps-excel-agent` and `ps-app-delfi` share the same orchestrator code

`ps-excel-agent\CalculationManager.cs` uses `using PlanningSpace.Integration.CalculationOrchestrator;` / `...Models;` — the **exact same namespace** as `ps-app-delfi`'s `PlanningSpace.Integration.Delfi.CalculationOrchestrator` project. Confirmed call chain:

1. `ps-excel-agent\CalculationManager.cs :: RunCalculation` (~line 366)
   - `_calculationController.CloneHierarchy(data.HierarchyName, true)` — clones the hierarchy before every calculation (non-advanced-calc path).
   - `_calculationController.RequestCalculation(calculationData, hierarchyId, "usePSLimit", "", [], data.SaveResults, 0)`
2. `PlanningSpace.Integration.Delfi.CalculationOrchestrator\CalculationController.cs :: RequestCalculation` (line 101)
   - `await _projectsController.ManageProjects(hierarchyId, model.FolderName, inputVariables, incrementalNodes, model.Projects, log);` (line 131)
3. `PlanningSpace.Integration.Delfi.CalculationOrchestrator\ProjectsController.cs :: ManageProjects` (line 24)
   - Existing projects → `PatchProjects` (line 298): sends `PATCH` with `Op = "replace", Path = "scenarios", Value = project.Scenarios` — **full overwrite** of the project's scenario list.
   - New projects → `CreateProjectsInFolder` (line 336): `POST .../projects` with the full `AgentProjectCreationRequestModel`.

**Implication:** there is no separate/duplicated patch logic in `ps-excel-agent` — any change to `ProjectsController.PatchProjects`/`ManageProjects` behavior in `ps-app-delfi`'s orchestrator project affects **both** consumers.

### Risk confirmed: full overwrite of `Scenarios` on PATCH
Because `PatchProjects` always does `Op: replace` on the **entire** `scenarios` array, REQ-025 ("existing project without a config row keeps its live PSE configuration") cannot be satisfied by simply omitting a scenario from the outgoing list — if the project is included in `AgentProjectCreationRequestModel.Projects` (which happens whenever it has any input rows), its scenario array gets replaced wholesale by whatever is sent, including scenarios that weren't part of the override.

**To satisfy REQ-024/025 correctly**, the eventual implementation must:
- Fetch the project's current scenarios from PSE (e.g. via the hierarchy `nodes` endpoint or a project-detail endpoint) before building the patch payload, **or**
- Merge: only replace the specific scenario(s) referenced by tags/override rows, and re-include any existing scenarios not touched by the current run, so the `replace` operation is effectively "safe" (full list is still correct after merge, but not clobbering untouched entries).

This is a design gap that must be resolved before implementing REQ-024/025/026 — currently no code path reads back a project's existing scenario configuration prior to patching.

---

## 6. Call-chain reference: where new fields would be consumed when sending to PSE

| Step | File | Method |
|---|---|---|
| 1. New row fields | `ps-excel-agent\...\Models\ExcelTableRowModel.cs` | `ExcelTableRowModel` — add `ProjectScenarioName` (+ new Scenario Configuration model) |
| 2. New collection on request model | `ps-excel-agent\...\Models\ExcelInputModel.cs` | `ExcelInputModel` — add `ScenarioConfiguration` |
| 3. Per-variable scenario resolution | `ps-excel-agent\...\CalculationManager.cs` | `CreateVariablesForProject(...)` (~936-995) |
| 4. Per-project `Scenarios` list assembly | `ps-excel-agent\...\CalculationManager.cs` | `GetExcelProjects(...)` (~780-905) |
| 5. Wraps into `CalculationModel` | `ps-excel-agent\...\CalculationManager.cs` | `ConvertExcelDataToCalculationModel(...)` (~716-750) |
| 6. Calculation entry point | `ps-excel-agent\...\CalculationManager.cs` | `RunCalculation(string id, ExcelInputModel data)` (~366) |
| 7. Shared orchestrator entry | `PlanningSpace.Integration.Delfi.CalculationOrchestrator\CalculationController.cs` | `RequestCalculation(CalculationModel model, int hierarchyId, ...)` (line 101) |
| 8. Project/scenario dispatch to PSE | `PlanningSpace.Integration.Delfi.CalculationOrchestrator\ProjectsController.cs` | `ManageProjects(...)` (24) → `PatchProjects(...)` (298) / `CreateProjectsInFolder(...)` (336) |
| 9. Model serialized to PSE JSON | `PlanningSpace.Integration.Delfi.CalculationOrchestrator\Models\AgentProjectCreationModel.cs` | `Scenarios` property (`List<ScenarioModel>`, SDK type) |
| 10. Actual HTTP calls | `ProjectsController.cs` | `_planningSpaceService.RequestStringAsync(HttpMethod.Post/PATCH, projectUrl, ...)` |

Note: `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\CalculationInputConverter.cs` (the FDPlan-side converter) is **not** part of this call chain — it's a separate, parallel path used only by the `ps-app-delfi` automated FDPlan pipeline, not by Excel-agent calculations.

---

## 7. Open items / next decisions
1. **Existing-project scenario merge strategy** (Section 5) — needs design before implementing REQ-024/025/026; no current code reads back PSE's existing scenario config prior to patch.
2. **`<scenario>` tag parsing utility** — not yet implemented anywhere; needed for REQ-021 and to avoid adding a breaking column to `PSECALCULATION`.
3. **DataType discriminator** (REQ-022) — decide whether `ScenarioConfiguration` rows live in the same table as `InputData` (discriminated by `DataType`) or a separate range/parameter (REQ-028 implies the latter — a dedicated range mapped to a new function parameter).
4. **Group Weighting** — explicitly deferred; no SDK/PSE API support found. Revisit if/when PSE API exposes it.
