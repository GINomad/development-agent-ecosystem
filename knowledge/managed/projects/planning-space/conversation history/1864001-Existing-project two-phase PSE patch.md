# 1864001 — Existing-project two-phase PSE patch

## Verified integration decision

For the traditional existing-project PlanningSpace calculation path, send settings, scenarios, and working-interest settings in a metadata bulk PATCH and await its job before sending variable overrides in a second bulk PATCH. Await that second job before calculation proceeds. A request or job failure in either phase prevents all later phases.

The variable-override contract remains `variableId`, `scenarioName`, `dataType`, and either scalar `value` or time-series `values`; `scenarioId` is not part of this change.

## Evidence

- `ps-app-delfi` commit `4da883d64fa7b3588126f0b6af9cdc7ea2656b26`: `ProjectsController.PatchProjects` and focused phase/failure tests.
- `ps-excel-agent` commit `6efde17aef052016596ba015d538c0b56e45f7cf`: local CalculationOrchestrator package consumption and retained scenario mapping regression.
- Task `task-1864001` `review-result.json`: clean review with R1–R7 verified and no findings.
- Task `task-1864001` `pipeline-result.json`: exact-SHA Delfi run `9146` succeeded.

## Scope boundary

Follow-up items R8–R14, including broader scenario-configuration behavior and merge semantics, remained held and were not changed.
