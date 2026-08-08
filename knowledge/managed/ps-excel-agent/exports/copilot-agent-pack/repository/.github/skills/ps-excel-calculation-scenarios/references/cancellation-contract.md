# Calculation lifecycle and cancellation contract

## Backend lifecycle

`CalculationManager.RequestCalculation` registers an in-memory job and should return the tracking GUID before long-running work occupies the request flow. The established local architecture explicitly queues calculation work:

```csharp
_ = Task.Run(() => RunCalculation(id, data));
```

A future hosted queue could be cleaner, but do not mix that redesign into a narrow fix.

Cancellation should account for pending and running jobs, token signaling, completion date, results/messages, and cleanup. Completed or unknown jobs should follow the current not-found/cannot-cancel API contract. Return normal cancelled results where established instead of using empty-message exceptions as control flow.

Use the current calculation-orchestrator API. Historical implementations used a local wait-or-cancel wrapper when the dependency did not expose a cancellation token; the current package version may differ.

## UI request path

Send cancellation through the shared `callApi` helper, not raw `fetch`, so auth headers, rotated token handling, and non-OK conversion remain consistent. Per-calculation cancellation is best effort; isolate failures so one request does not hide attempts for other active calculations.

Shortcut flows may lack a custom-function cell address. Keep console logging but skip workbook log-table writes when the address is empty or uninitialized.

## Final confirmed user trigger

The reliable final direction was:

- keep `PSECANCELCALCULATIONS` as a public Office.js custom function and in `functions.json`;
- let VBA own `Application.OnKey` (`Ctrl+Shift+Alt+X`, represented as `^+%x`);
- have VBA write `=QUORUM.PSECANCELCALCULATIONS()` into a workbook cell and calculate it;
- use a workbook selection-change hook for lazy shortcut registration after macros are enabled;
- unregister the shortcut before workbook close.

Do not call the Office.js function through `Application.Run`; Office.js custom functions are reliably exposed through Excel's formula engine, not as VBA/XLL macros. Office.js also cannot directly invoke VBA.

The following approaches were tried and rejected for the standalone Excel desktop path:

- relying on `CustomFunctions.CancelableInvocation`/`@cancelable` for user Esc cancellation;
- Office.js `KeyboardShortcuts 1.1`, `ExtendedOverrides`, `shortcuts.json`, and `Office.actions.associate` as the primary shortcut path;
- warm-up calls as a permanent fix for shortcut metadata timing;
- direct Office.js-to-VBA or VBA-to-Office.js macro invocation.

If requirements change to worksheet-scoped cancellation, treat it as a new design: validate worksheet-name escaping, workbook identity, tracking-map semantics, and compatibility before editing the established global cancel behavior.
