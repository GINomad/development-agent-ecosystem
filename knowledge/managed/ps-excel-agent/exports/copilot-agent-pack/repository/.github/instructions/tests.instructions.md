---
name: PS Excel test rules
description: Focused verification and regression coverage for backend and UI changes.
applyTo: "{planningspace.integration.excel.agentTests/**/*.cs,planningspace.integration.excel.ui/**/*.test.*,Test Files/**}"
---

- Prefer deterministic unit tests over timing-dependent sleeps.
- For refresh-token concurrency, coordinate callers so overlap is proven and assert the token endpoint call count plus shared rotated result.
- For cancellation, cover pending, running, completed/not-found, cleanup, and normal cancelled-result behavior as applicable.
- For scenario changes, cover default `Base`, tagged and untagged variable rows, scalar and time-series parity, duplicate configuration keys, defaults, and existing-project overwrite risks.
- Do not modify `.xlsm`/`.xlsx` binary fixtures unless explicitly asked. Describe manual workbook verification separately from automated test results.
- Report pre-existing warnings separately from failures, and never claim a command passed if it was skipped or blocked.
