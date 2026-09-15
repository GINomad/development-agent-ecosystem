# PS Excel Agent repository instructions

This repository implements a Planning Space integration for Microsoft Excel:

- `planningspace.integration.excel.agent`: ASP.NET Core API, currently targeting .NET 10 with nullable reference types and implicit usings.
- `planningspace.integration.excel.agentTests`: MSTest/Moq backend tests.
- `planningspace.integration.excel.ui`: React 18, TypeScript, Webpack, Office.js shared runtime/custom functions, Redux Toolkit, OIDC client.
- `Manifests`: Excel add-in manifests.
- `Test Files`: workbook-based manual test assets; do not rewrite binary workbooks unless explicitly requested.

Repository-wide rules:

- Use braces for every `if`, `else if`, and `else`, including one-line bodies.
- Put each C# class in its own file. Use explicit access modifiers and the narrowest practical visibility. Do not declare helper methods inside methods.
- Prefer `using` directives over fully qualified types in signatures.
- Do not add controller-level `try`/`catch` wrappers without explicit approval. Preserve the established controller error path.
- Reuse shared UI API helpers, authentication/token-update helpers, and logging helpers instead of introducing raw parallel implementations.
- Preserve the separation between UI range parsing, API DTOs, orchestration, and Planning Space models.
- Treat authentication, calculation lifecycle, scenario mapping, runtime `env.js`, Office manifests, and Docker/Azure configuration as high-risk areas. Read the matching skill before changing them.
- Never place access tokens, refresh tokens, PATs, client secrets, or private credentials in code, logs, prompts, or configuration committed to Git.
- Knowledge references capture decisions from earlier work. Verify them against the active branch because target frameworks, package versions, APIs, and implementation details can change.

Typical verification from the repository root:

```powershell
dotnet test ps-excel-agent.sln --no-restore
Push-Location planningspace.integration.excel.ui
npm run build:dev
npm run lint
npm run validate
Pop-Location
```

Select only the checks relevant to the change. A production UI build uses `npm run build`; a Release backend build uses `dotnet build ps-excel-agent.sln -c Release`.
