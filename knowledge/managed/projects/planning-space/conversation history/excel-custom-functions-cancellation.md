# Excel Custom Functions Cancellation Summary

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base: `C:\Repos\AI Knowledge\ps_excel_agent`
Created: 2026-07-01

## Conversation Goal

Extend the Excel add-in custom functions `PSECALCULATION` and `PSECALCULATIONFROMJSON` so Excel can cancel long-running calculations. Cancellation should call the backend `DELETE /api/v1/calculation?id={trackingGuid}` endpoint and should be based only on the cancellation-related parts of PR 23113, not on unrelated bearer-token refresh, persistence, certificate, or framework-upgrade changes.

## UI Pattern

Custom functions that need Excel cancellation should use `CustomFunctions.CancelableInvocation`, include the JSDoc `@cancelable` tag, and have `"cancelable": true` in `functions.json` metadata.

The cancellation handler is `invocation.onCanceled` with one `l` in `Canceled`.

Preferred pattern in `functions.ts`:

```ts
invocation.onCanceled = requestCancellation;
```

`requestCancellation` records cancellation state and, after the backend tracking GUID is known, sends:

```ts
DELETE ${env.ExcelAgentApiUrl}/api/v1/calculation?id=${trackingGuid}
```

Do not use `throw new CustomError("")` as normal cancellation control flow. Return a normal `CalculationRunResult` with status `Cancelled`, empty output data, and any available messages.

## Backend Pattern

`CalculationManager.CancelCalculation(string id)` should accept both `Pending` and `Running` calculations:

- `Pending`: immediately set status to `Cancelled`, set empty results/messages, and set `CompletedDate`.
- `Running`: signal a per-calculation `CancellationTokenSource`.

Each `Calculation` has a `CancellationTokenSource Cts`.

For the current `net9.0` / `PlanningSpace.Integration.CalculationOrchestrator` version, `WaitForCompletion` does not expose the PR's named `cancellationToken` argument. Use a local `WaitOrCancel` wrapper around the existing `WaitForCompletion(...)` task rather than pulling in the broader PR upgrade to `net10.0` and orchestrator `1.33.4`.

Handle `OperationCanceledException` in `RunCalculation` by setting status to `Cancelled`, preserving empty/partial results, adding `Info: Calculation was cancelled.`, setting `CompletedDate`, and running cleanup when results are not saved.

## API Endpoint

`CalculationController.Delete(string id)` returns:

- `Ok()` when cancellation was accepted.
- `NotFound()` when the calculation id was not found or is already complete.

Preserve the existing controller auth-token application pattern. Do not add new controller-level `try`/`catch` blocks without approval.

## Verification Used

```powershell
dotnet build ps-excel-agent.sln
cd planningspace.integration.excel.ui
npm run build:dev
```

Both builds passed after the cancellation changes. Expected non-blocking output may include NuGet credential-provider warnings and Browserslist outdated-data warning.

## Commit Message Draft

```text
Make Excel custom calculations cancellable

- Mark PSECALCULATION and PSECALCULATIONFROMJSON as cancelable functions
- Send DELETE cancellation requests from Excel onCanceled handlers
- Return a normal Cancelled calculation result instead of throwing for user cancellation
- Support pending and running cancellation in CalculationManager
- Wrap Planning Space completion waits with local cancellation handling
- Return 404 from DELETE when a calculation cannot be cancelled
```
## 2026-07-02 Follow-up

The current reliable UI cancellation path is the custom Office shortcut, not `CustomFunctions.CancelableInvocation` / `@cancelable`.

Refinement made in `planningspace.integration.excel.ui/src/functions/functions.ts`:

- Removed temporary shortcut diagnostics and noisy console logging.
- Kept `event.completed()` in both success and error branches of `.then(...)` so Office is always notified after async cancellation work finishes.
- Avoided `Promise.prototype.finally` for older Excel runtime compatibility.
- Sent DELETE cancellation requests through shared `callApi` instead of raw `fetch`, preserving auth headers, token-rotation handling, and non-OK error handling.
- Added an English comment explaining the intentional `.then(success, error)` pattern.

Verification used:

```powershell
cd planningspace.integration.excel.ui
npm run build:dev
```

The UI build passed. Expected non-blocking output may include the Browserslist outdated-data warning.
## 2026-07-02 Logging Follow-up

Shortcut action handlers can run without a custom-function invocation address. Calling `logInfo`, `logWarning`, or `logError` with an empty address attempted to write to the Excel `PSE_Logs` table and could fail.

Refinement made in `planningspace.integration.excel.ui/src/taskpane/utils/logging.ts`:

- Keep console logging behavior for empty-address calls.
- Skip Excel log-sheet writes when `address` is empty or `logItems[address]` has not been initialized.
- This protects the `CancelCalculations` shortcut path when there are no active calculations or when cancellation logging happens outside a cell-bound invocation.

Verification used:

```powershell
cd planningspace.integration.excel.ui
npm run build:dev
```

The UI build passed. Expected non-blocking output may include the Browserslist outdated-data warning.
## 2026-07-03 Shortcut Registration Follow-up

Standalone Excel desktop testing showed that keyboard shortcut registration can differ from the `office-addin-debugging` dev-server flow.

Observed facts:

- The add-in manifest version/label updated correctly.
- `KeyboardShortcuts 1.1` and `SharedRuntime 1.1` were supported by the Excel runtime.
- Excel requested `/shortcuts.json` from `ExtendedOverrides`.
- Manual fetch of `/shortcuts.json` returned `200` and valid JSON.
- `Office.actions.associate("CancelCalculations", ...)` succeeded; a second console registration returned `DuplicatedName`.
- Despite that, `Office.actions.getShortcuts()` could be `{}` and `replaceShortcuts({ CancelCalculations: ... })` could fail with `InvalidArgument`, showing that JS action association and Office shortcut metadata registration are separate.
- Restoring diagnostic calls caused shortcuts to start working, suggesting an Excel desktop shortcut subsystem initialization/timing issue.

Superseded workaround from this point in the investigation:

- Keep `CancelCalculations` associated through `Office.actions.associate`.
- After association, quietly warm up the shortcut subsystem by calling `Office.actions.getShortcuts()` and `Office.actions.areShortcutsInUse(["Ctrl+Shift+Alt+X"])`.
- Check only `Ctrl+Shift+Alt+X`; forget the previous `Q` experiments.
- Keep `/shortcuts.json` static response headers in the ASP.NET standalone host: `Access-Control-Allow-Origin: *` and `Cache-Control: no-store`.
- A taskpane fallback button was tried and worked, but was removed while testing the warm-up-only shortcut path.

Builds used after the warm-up-only path:

```powershell
cd planningspace.integration.excel.ui
npm run build
cd ..
 dotnet build ps-excel-agent.sln -c Release
```

Expected UI production build warnings include webpack asset/entrypoint size warnings and outdated Browserslist data. Backend Release build passed with zero warnings/errors.
## 2026-07-07 Cancellation Function Final Direction

The Office.js keyboard-shortcut path was abandoned. It was too dependent on Excel desktop metadata registration timing and behaved differently between normal standalone runs, admin runs, and `office-addin-debugging` / VS Code debugger attach flows.

Final direction:

- Keep `PSECANCELCALCULATIONS` as a public Office.js custom function in `planningspace.integration.excel.ui/src/functions/functions.ts`.
- Keep `PSECANCELCALCULATIONS` in `src/functions/functions.json` so Excel can call it through the formula engine.
- Remove JavaScript shortcut registration (`Office.actions.associate(...)`) from `functions.ts`.
- Remove `KeyboardShortcuts 1.1`, `ExtendedOverrides`, `src/functions/shortcuts.json`, webpack copying of `shortcuts.json`, and ASP.NET `/shortcuts.json` diagnostics/headers.
- Trigger the public cancellation function from VBA by writing a formula such as `=QUORUM.PSECANCELCALCULATIONS()` into a workbook cell and calculating it.

Working VBA approach:

- Keep shortcut registration code in a normal VBA module with `Application.OnKey`.
- Use `Ctrl+Shift+Alt+X`, represented by VBA as `^+%x`.
- Handle the shortcut in VBA by clearing `A1`, writing `=QUORUM.PSECANCELCALCULATIONS()`, and calculating `A1`.
- Use `Workbook_SheetSelectionChange` in `ThisWorkbook` as a lazy registration hook. This worked after macros were enabled: once the user changes selection, `RegisterPseCancelShortcut` runs and the shortcut becomes active.

Important limitations discovered:

- If macros are disabled when the workbook opens, no VBA open/application/worksheet event runs. Excel also does not fire a VBA event when the user clicks Enable Content.
- `Auto_Open` and `Workbook_Open` are useful only when macros are already trusted/enabled at open time.
- `Application.Run("QUORUM.PSECANCELCALCULATIONS")` is not reliable for Office.js custom functions. Office.js custom functions are callable by Excel's formula engine, not as VBA/XLL macros.
- Office.js cannot directly call VBA macros. There is no supported Office.js equivalent of `Application.Run`.
- `Worksheet_Change` fires when a cell's contents are changed directly, not when a formula result changes after recalculation. `Worksheet_Calculate` fires after recalculation but does not identify which custom function started.

Verification after cleanup:

```powershell
cd planningspace.integration.excel.ui
npm run build
cd ..
dotnet build ps-excel-agent.sln -c Release
```

Both builds passed. Expected UI warnings are the existing webpack bundle-size warnings and outdated Browserslist data.

## 2026-07-13 Concept: Worksheet-Scoped Cancellation

Status: Concept / parked for later.

Context:

- The current working cancellation trigger is VBA: `Application.OnKey` handles the shortcut and writes a formula such as `=QUORUM.PSECANCELCALCULATIONS()` into a workbook cell.
- `PSECANCELCALCULATIONS` currently cancels all active calculations tracked in the Office.js custom-functions runtime.
- Active calculations are tracked by `trackingGuid` and `address` in `src/functions/functions.ts`.
- The observed `invocation.address` format in logs is like `ASYNC!E6`, where `ASYNC` is the worksheet name and `E6` is the cell address.

Concept:

Use the worksheet name from `invocation.address` to cancel only calculations that belong to the active worksheet from which the VBA shortcut was invoked.

Possible implementation shape:

1. VBA passes the active worksheet name to the public cancellation custom function:

```vb
.Formula = "=QUORUM.PSECANCELCALCULATIONS(""" & ActiveSheet.Name & """)"
```

2. `PSECANCELCALCULATIONS` accepts an optional worksheet name:

```ts
export async function PSECANCELCALCULATIONS(worksheetName?: string): Promise<string> {
  await cancelAllActiveCalculationsAsync(worksheetName);
  return "Cancellation requested for active calculations.";
}
```

3. `cancelAllActiveCalculationsAsync` filters `activeCalculations` by worksheet name parsed from the stored `address`.

Potential helper:

```ts
function getWorksheetNameFromAddress(address: string): string | null {
  const bangIndex = address.lastIndexOf("!");
  if (bangIndex < 0) {
    return null;
  }

  return address.slice(0, bangIndex).replace(/^'|'$/g, "");
}
```

Notes / risks:

- This is worksheet-scoped, not workbook-scoped. `ASYNC!E6` identifies a worksheet and cell, not a workbook.
- Sheet names with spaces may appear quoted, for example `'My Sheet'!E6`; parsing should strip surrounding single quotes.
- Matching should probably normalize whitespace and case.
- If no worksheet name is passed, the function can preserve the current behavior and cancel all active calculations.
- Workbook-scoped cancellation would require explicitly passing and storing a workbook identity when calculations start, not only when cancellation is requested.

No code changes were made for this concept yet.
