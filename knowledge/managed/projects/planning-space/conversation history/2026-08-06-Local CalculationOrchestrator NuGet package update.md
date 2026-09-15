# Local CalculationOrchestrator NuGet package update

## Date

2026-08-06

## Task

Build a local `PlanningSpace.Integration.CalculationOrchestrator` NuGet package from `C:\Repos\ps-app-delfi` and update `C:\Repos\ps-excel-agent` to consume it from the local NuGet feed.

The Excel agent originally referenced:

```xml
<PackageReference Include="PlanningSpace.Integration.CalculationOrchestrator" Version="1.32.20251007.202510071" />
```

The source repository contained working-tree changes in `ProjectsController.cs`, its tests, and the orchestrator project file. The controller change makes duplicate detection scenario-aware by including `ScenarioName` in the duplicate key.

## Versioning decision

The historical package convention was:

```text
1.32.<yyyyMMdd>.<BuildNumberWithoutPunctuation>
```

The current pipeline uses the `1.33` version line. The local package version was therefore set to:

```text
1.33.20260806.202608061
```

`PackageVersion` in the source project was updated to this value. `AssemblyVersion` and `FileVersion` remain `1.0.32` to avoid changing the binary assembly identity as part of a package-only version update.

## Packages created

The following packages were created in `C:\NugetStore`, all with version `1.33.20260806.202608061`:

- `PlanningSpace.Integration.CalculationOrchestrator`
- `PlanningSpace.Integration.Common`
- `PlanningSpace.Integration.Utilities`
- `PlanningSpace.Integration.PlanningSpaceClient`
- `PlanningSpace.Integration.AdvancedCalculations`

The main package is:

```text
C:\NugetStore\PlanningSpace.Integration.CalculationOrchestrator.1.33.20260806.202608061.nupkg
```

Its nuspec references all four internal dependencies at the same version. The package in `C:\NugetStore` and the copy restored into the global NuGet cache have identical SHA-256 hashes.

## Excel agent changes

- Updated `planningspace.integration.excel.agent.csproj` to reference `1.33.20260806.202608061`.
- Added `LocalDevNuget` mapping for `PlanningSpace.Integration.*` in `NuGet.Config`. The source was already registered globally as `C:\NugetStore`, but package source mapping excluded it, causing restore to ignore the local package.
- Adapted `CalculationManager.cs` to the new orchestrator result model, where result rows are `Dictionary<string, object>` with native CLR values instead of `Dictionary<string, JsonElement>`.
- Updated the calculation result test fixture accordingly.

## Verification

- `ps-app-delfi` CalculationOrchestrator tests: 40 passed.
- `ps-excel-agent` solution build: passed with 0 warnings and 0 errors.
- `ps-excel-agent` tests: 21 passed.
- Restore confirmed that the requested package version was resolved from `LocalDevNuget`.

Existing unrelated working-tree files in `ps-excel-agent` (`package-lock.json` and `Test Files/~$Project Scenario.xlsm`) were left untouched.