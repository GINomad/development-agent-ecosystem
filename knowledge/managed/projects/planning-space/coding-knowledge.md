# PS Excel Agent Coding Knowledge

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base path: `C:\Repos\AI Knowledge\ps_excel_agent`
Created: 2026-06-30

## AsyncLocal and ScopedContext

`PlanningSpace.Integration.Utilities.ScopedContext.PsAccessToken` is backed by `AsyncLocal<string>`. Values written to `AsyncLocal` are bound to the current async execution context, not to a normal global static field.

### Observed Case

`AuthHelper.ExtractAccessTokens(HttpRequest request)` worked because it synchronously extracted the bearer token from the incoming request and wrote it to `ScopedContext.PsAccessToken` in the controller action flow.

`AuthHelper.ExtractAccessTokensAsync(HttpRequest request, IPlanningSpaceTokenService tokenService)` did not work reliably even when the token did not need refresh. The method awaited token-service work and then wrote to `ScopedContext.PsAccessToken` inside the async helper continuation. Downstream Planning Space calls did not see the token as expected.

### Rule

Do not write `ScopedContext` / `AsyncLocal` values inside helper methods after an `await` when downstream code depends on those values in the caller flow.

### Preferred Pattern

Split async token retrieval from synchronous context application:

```csharp
var accessToken = await AuthHelper.GetAccessTokenAsync(Request, tokenService);
AuthHelper.ExtractAccessTokens(Request, accessToken);
```

`GetAccessTokenAsync` may await refresh/validation logic and return the token. `ExtractAccessTokens` should synchronously write the already resolved token and credentials into `ScopedContext`.

### Why

This keeps `ScopedContext.PsAccessToken` assignment in the controller action execution flow, avoiding surprises from `AsyncLocal` context propagation across async helper continuations.

### Related Files

- `planningspace.integration.excel.agent/V1/Helpers/AuthHelper.cs`
- `planningspace.integration.excel.agent/V1/Controllers/CalculationController.cs`
- `planningspace.integration.excel.agent/Authentication/PlanningSpaceTokenService.cs`

## Parallel Refresh-Token Rotation

Final direction as of 2026-07-20: parallel Excel calculations that present the same expiring access token and refresh token must share one refresh operation and one rotated token result.

### Observed Failure

A production-style log contained five interleaved calculation flows. Once the access token entered the refresh buffer, the agent sent 149 requests to `/identity/connect/token`:

- one refresh returned `200`;
- 148 refreshes returned `400`;
- up to three refreshes were in flight at the same time;
- all 161 downstream Planning Space responses still succeeded with `200`, `201`, or `202`.

This pattern is consistent with rotating refresh-token reuse. The first request consumes the old refresh token and receives a new token pair. Parallel requests still carrying the old token are then rejected. The exact OAuth error was not present because `PlanningSpaceTokenService` discarded the token endpoint response body.

Business calls temporarily continued because refresh begins before access-token expiry and the old implementation silently fell back to the still-valid old access token. This is only temporary; after actual expiry, authorization can fail before the controller can refresh.

### Required Backend Pattern

`PlanningSpaceTokenService` is registered as a singleton and coordinates refreshes per `clientId + refreshToken`:

- hash the pair with SHA-256 so the raw refresh token is not used as a dictionary key;
- store a `Lazy<Task<AccessTokenResponse?>>` per hash;
- use `LazyThreadSafetyMode.ExecutionAndPublication` so only one Identity request executes;
- return the same successful rotated access/refresh token result to all parallel callers;
- retain the successful result for the configured refresh-buffer duration so a slightly late request carrying the old pair can also recover;
- remove unsuccessful operations so a transient failure is not cached for the whole buffer.

A plain `SemaphoreSlim` without result reuse is insufficient. Waiting requests would enter the semaphore later but would still submit the already-consumed refresh token.

Coordination is per token hash, not global. Different users/token pairs can refresh in parallel. The current in-memory approach coordinates one Excel Agent process. A multi-instance deployment would require shared/distributed coordination.

### Required UI Pattern

`callApi` must read the latest `User` from `userManagerPS.getUser()` immediately before constructing request headers. Do not rely only on the `User` object captured when a long-running custom function started.

After a response, pass that current user object to `updateUserTokens` so rotated access token, refresh token, and expiry are persisted consistently.

### Verification

`PlanningSpaceTokenServiceTests.GetTokenAsyncSharesRotatedTokensBetweenParallelRequests` covers five parallel callers plus a late caller presenting the old token pair. Expected behavior:

- the token endpoint is called exactly once;
- every caller receives the same rotated token pair;
- every result reports `WasRefreshed = true`.

After the implementation, all 12 .NET tests passed and the UI development build completed successfully.

### Related Files

- `planningspace.integration.excel.agent/Authentication/PlanningSpaceTokenService.cs`
- `planningspace.integration.excel.agentTests/PlanningSpaceTokenServiceTests.cs`
- `planningspace.integration.excel.ui/src/taskpane/utils/helpers.ts`
- `planningspace.integration.excel.ui/src/session/updateUserTokens.ts`

## Excel Calculation Cancellation

Final direction as of 2026-07-06: use VBA to own the keyboard shortcut and keep `PSECANCELCALCULATIONS` as a public Office.js custom function that Excel can invoke through the formula engine.

### What Worked

The reliable user-facing cancellation path is:

- `PSECALCULATION` and `PSECALCULATIONFROMJSON` track active calculation tracking GUIDs in `src/functions/functions.ts`.
- `PSECANCELCALCULATIONS` remains exported as a public Office.js custom function and registered in `functions.json`.
- VBA handles the keyboard shortcut with `Application.OnKey`.
- The VBA shortcut handler writes a formula such as `=QUORUM.PSECANCELCALCULATIONS()` into a workbook cell, e.g. `A1`, and calculates it. This bridges VBA to Office.js through Excel's normal formula engine.
- `Workbook_SheetSelectionChange` in `ThisWorkbook` can lazily call the module-level `RegisterPseCancelShortcut` after a user enables macros and changes selection. This worked when `Auto_Open` could not run because macros were disabled at workbook open.

Recommended VBA shape:

```vb
' Module1.bas
Public Const PSE_CANCEL_SHORTCUT As String = "^+%x"
Private pseShortcutRegistered As Boolean

Public Sub RegisterPseCancelShortcut()
    If pseShortcutRegistered Then
        Exit Sub
    End If

    Application.OnKey PSE_CANCEL_SHORTCUT, "PseCancelCalculations"
    pseShortcutRegistered = True
End Sub

Public Sub UnregisterPseCancelShortcut()
    Application.OnKey PSE_CANCEL_SHORTCUT
    pseShortcutRegistered = False
End Sub

Public Sub PseCancelCalculations()
    On Error GoTo ErrorHandler

    With ActiveWorkbook.ActiveSheet.Range("A1")
        .ClearContents
        .Formula = "=QUORUM.PSECANCELCALCULATIONS()"
        .Calculate
    End With

    Exit Sub

ErrorHandler:
    MsgBox "Failed to cancel PSE calculations: " & Err.Description, vbExclamation
End Sub
```

```vb
' ThisWorkbook
Private Sub Workbook_SheetSelectionChange(ByVal Sh As Object, ByVal Target As Range)
    On Error Resume Next
    RegisterPseCancelShortcut
    On Error GoTo 0
End Sub

Private Sub Workbook_BeforeClose(Cancel As Boolean)
    On Error Resume Next
    UnregisterPseCancelShortcut
    On Error GoTo 0
End Sub
```

### Approaches Tried And Rejected

- `CustomFunctions.CancelableInvocation` / `@cancelable`: unreliable in Excel desktop with the current Office.js runtime. Cancellation callbacks could be delayed, fire during normal recalculation noise, or not fire on `Esc` as expected. The workbook also showed repeated recalculation / `BUSY` states while the function was running.
- Office.js keyboard shortcuts via manifest `ExtendedOverrides`, `shortcuts.json`, and `Office.actions.associate(...)`: unreliable in standalone ASP.NET-hosted Excel add-in runs. Excel could fetch `shortcuts.json` and `associate` could succeed, but loaded shortcut metadata was empty or unavailable in normal user runs. Admin/debugger/office-addin-debugging contexts behaved differently, so this path was not dependable enough.
- Shortcut warm-up calls such as `Office.actions.getShortcuts()` / `areShortcutsInUse(...)`: not reliable. In the standalone context these APIs could throw `Invalid API call in the current context`.
- Calling Office.js custom functions from VBA with `Application.Run("QUORUM.PSECANCELCALCULATIONS")`: failed because Office.js custom functions are visible to Excel's formula engine, not reliably callable as VBA/XLL macros.
- Calling VBA directly from Office.js: no supported API equivalent to `Application.Run` exists in Office.js. A bridge must go through workbook state/formulas/events, not direct runtime calls.

### Cancellation Request API Calls

When sending cancellation requests from `src/functions/functions.ts`, use the shared `callApi` helper instead of raw `fetch`. This keeps DELETE cancellation requests aligned with normal API calls:

- Authorization, `PS-Tenant`, `PS-Client-Id`, and optional `PS-Refresh-Token` headers are applied consistently.
- Rotated access/refresh tokens returned by the backend are stored through `updateUserTokens`.
- Non-OK responses such as `401` or `404` become `CustomError`s and are logged as cancellation warnings instead of false "requested" success messages.

Cancellation should remain best-effort by catching each per-calculation cancellation request inside the `Promise.all` mapping.

### Logging Without Cell Address

Shortcut paths do not necessarily provide a custom-function invocation address. Do not call Excel log-sheet writes with an empty address from shortcut-only paths. The shared logging helper should keep console logging but skip `PSE_Logs` table writes when `address` is empty or `logItems[address]` has not been initialized by `recreateLoggingSheetAsync(address)`.
## Background Calculation Launching

`CalculationManager.RequestCalculation` intentionally launches the long-running calculation as background work and returns the tracking GUID immediately.

Prefer the current pattern:

```csharp
_ = Task.Run(() => RunCalculation(id, data));
```

This queues `RunCalculation` on the thread pool so the HTTP request flow only registers the in-memory job and returns the id.

The older pattern:

```csharp
_ = RunCalculation(id, data);
```

is also fire-and-forget, but an async method starts executing synchronously on the current request flow until it reaches the first incomplete `await`. If early awaits complete synchronously, part of the calculation can run inside `RequestCalculation` before the GUID is returned.

In a larger redesign, an ASP.NET `BackgroundService` plus a queue would be cleaner for long-lived background work. Within the current in-memory job architecture, `Task.Run` makes the separation from the HTTP request explicit.
### Logging Without Cell Address

Office shortcut actions do not provide a custom-function invocation address. Do not call Excel log-sheet writes with an empty address from shortcut-only paths. The shared logging helper should keep console logging but skip `PSE_Logs` table writes when `address` is empty or `logItems[address]` has not been initialized by `recreateLoggingSheetAsync(address)`.

This prevents shortcut actions such as `CancelCalculations` from failing while trying to append a row for a blank range.
### Office Shortcut Registration Warm-up

In standalone/sideloaded Excel desktop runs, Excel can request `shortcuts.json` from `ExtendedOverrides` and still leave `Office.actions.getShortcuts()` empty until the shortcut API is queried from the shared runtime. `Office.actions.associate(...)` can succeed independently of shortcut metadata registration: a duplicate `associate` call may throw `DuplicatedName` even when `getShortcuts()` is `{}` and `replaceShortcuts({ CancelCalculations: ... })` fails with `InvalidArgument`.

Keep a quiet warm-up after associating the action:

```ts
void warmUpCancelShortcutAsync();
```

The warm-up should call `Office.actions.getShortcuts()` and `Office.actions.areShortcutsInUse(["Ctrl+Shift+Alt+X"])`. Treat this as an Excel desktop runtime workaround, not normal business logic. Check only the active shortcut key; the current chosen shortcut is `Ctrl+Shift+Alt+X` / `Command+Shift+Option+X`.

For standalone ASP.NET hosting, serve `/shortcuts.json` with:

- `Access-Control-Allow-Origin: *`
- `Cache-Control: no-store`

A temporary server-side log for `/shortcuts.json` is useful while diagnosing whether Excel's native metadata loader requests the file during add-in registration.

## Change Review Workflow

After every code or knowledge-base edit, open the diff in the user's IDE automatically. Show the baseline on the left and the current version on the right for every task-related file. For new files, use an empty baseline. Keep the detailed preference in `coding-style.md`.
## Deferred EMV / EV Reference

Status as of 2026-07-21: special EMV handling was removed from the Excel Agent and will be implemented as a separate change. Do not add EMV-specific branches, constants, payload conversion, validation, or tests as part of the current named-scenario work.

Retained domain knowledge for that future change:

- EMV means Expected Monetary Value (EV) over all configured project scenarios; it is not a scenario named `EMV`.
- Scenario weights mathematically total `1.00`, while the SDK represents them as percentages (`100` means `1.00`).
- A removed prototype mapped the general EMV setting to an empty calculation scenario and empty project-settings scenario, preserved tagged row scenarios, left untagged variable scenarios empty, and did not create an `EMV` `ScenarioModel`.
- The prototype's payload shape had unit coverage but was never confirmed end to end against live PSE, so it must not be treated as supported behavior.
- Before reimplementation, confirm the EV calculation signal, project-settings behavior, untagged-variable semantics, weighting validation, and full existing-project scenario merge strategy.

Current non-EMV routing remains:

- blank general Project Scenario defaults to `Base`;
- a final `<ScenarioName>` path node sets `Variable.ScenarioName`;
- tagged Variables are forwarded with their row scenario even when it differs from the general named scenario;
- untagged Variables use the named/default general scenario;
- scalar and time-series Variables use the same resolution logic.

Existing-project caution: the shared orchestrator replaces the complete `scenarios` array, so preserving omitted PSE scenarios requires a full read/merge or different patch behavior.

## Scenario-Aware Duplicate Variable Validation

Confirmed in `ps-app-delfi`: `ProjectsController.CheckForDuplicates` scopes duplicate input variables by project path, variable alias, and `GenericVariableDataModel.ScenarioName`. Do not infer the scenario from the project path or use `AgentProjectCreationModel.Scenarios` as the per-variable discriminator; that collection defines available scenario configuration.

`CalculationManager.CreateVariablesForProject` in `ps-excel-agent` assigns the resolved row scenario directly to `ScenarioName` for both scalar and time-series variables. The same alias can therefore be sent for one project under different scenario names, while a repeated alias under the same scenario must be rejected. Duplicate messages include `"{ProjectPath}/{VariableAlias}/{ScenarioName}"`.

Evidence: `PlanningSpace.Integration.Delfi.CalculationOrchestrator/ProjectsController.cs`, `PlanningSpace.Integration.Delfi.CalculationOrchestratorTests/ProjectControllerTests.cs`, and `ps-excel-agent/planningspace.integration.excel.agent/CalculationManager.cs`. Focused orchestrator tests passed: 40 tests with `dotnet test PlanningSpace.Integration.Delfi.CalculationOrchestratorTests/PlanningSpace.Integration.CalculationOrchestratorTests.csproj --no-restore`.

## Separate Ranges Do Not Need a DataType Discriminator

Decision as of 2026-07-23: do not add a `DataType` field to Excel input DTOs when Input Variables and Scenario Configuration are supplied as separate ranges and serialized as separate collections.

Use the request structure as the discriminator:

- `ExcelInputModel.InputData` contains only `ExcelTableRowModel` rows;
- `ExcelInputModel.ScenarioConfiguration` contains only `ExcelScenarioConfigurationRowModel` rows.

Keep fixed range layouts. Do not add automatic typed/untyped column-shift detection to `functions.ts`; it makes positional parsing ambiguous and duplicates information already expressed by the selected range and target model.

A string `DataType` discriminator is appropriate only if both row kinds are intentionally combined into one heterogeneous collection. If that design is chosen in the future, use a proper discriminated union and validate the discriminator strictly rather than duplicating it across separate DTO collections.

The current separate-range decision conflicts with the literal DataType wording in REQ-XLEAAS-022/023 and AC3. Requirements should be aligned with the AC9 separate-range contract.
## Keep a Migration Path from Global to Per-Project Scenario Configuration

Provisional direction as of 2026-07-23: model Scenario Configuration as a global list keyed by `ScenarioName`, shared across projects. Project and variable targeting remains in Input paths; untagged Inputs use the Settings scenario and ultimately default to `Base`.

This global model is now implemented in the agent and UI payload. Scenario Configuration has no project `Path`; its first Excel column and JSON property are `ScenarioName`.

Do not treat the global scope as confirmed product behavior. If per-project differences are required later, extend the configuration model with an optional explicit `ProjectPath` rather than returning to an overloaded combined path field.

Use these keys and precedence:

1. Project-specific `(ProjectPath, ScenarioName)`.
2. Global `(ScenarioName)`.
3. Scenario defaults.

A blank `ProjectPath` represents a global row. Validate duplicates independently for global and project-specific keys. Keep Input scenario resolution unchanged.

The detailed fallback model, range layout, and implementation touchpoints are documented in the task history file `1838084-[Inputs] Support per-project scenario targeting and configuration.md`.
