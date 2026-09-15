---
name: ps-excel-calculation-scenarios
description: Diagnose or change Excel calculation lifecycle, custom-function input ranges, scenario path parsing, scenario configuration, variable scenario routing, EMV/EV behavior, cancellation, tracking IDs, calculation cleanup, and Office/VBA cancellation integration in ps-excel-agent.
---

# Calculations, scenarios, and cancellation

1. Read [references/scenario-contract.md](references/scenario-contract.md) for scenario or range work.
2. Read [references/cancellation-contract.md](references/cancellation-contract.md) for calculation lifecycle, cancellation, shortcut, or VBA work.
3. Trace TypeScript range parsing through C# DTO validation into Planning Space project/scenario/variable creation.
4. Preserve scalar and time-series parity unless requirements explicitly differ.
5. Treat scenario collection replacement on existing projects as a data-loss risk.
6. Verify focused parser/helper/manager tests and the UI build when the custom-function contract changes.

Do not reintroduce abandoned EMV behavior, a `DataType` discriminator, or Office.js shortcut registration without a newly confirmed product/runtime decision.
