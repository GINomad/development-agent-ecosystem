# Verification guide

Choose checks based on the changed surface; do not run commands merely to create the appearance of coverage.

## Backend

From the repository root:

```powershell
dotnet test ps-excel-agent.sln --no-restore
```

Use `dotnet build ps-excel-agent.sln -c Release` when Release packaging/build behavior matters. If dependencies are not restored, run the appropriate restore only when network/feed access is authorized and available.

## UI

From `planningspace.integration.excel.ui`:

```powershell
npm run build:dev
npm run lint
```

Use `npm run build` for production bundling behavior. Use `npm run validate` when the active UI manifest changes. Validate `Manifests/manifestDev001.xml` explicitly when that separate manifest changes.

## Focus areas

- Auth/concurrency: targeted token-service tests plus UI build.
- Calculation/scenario: targeted parser/helper/manager tests plus UI build if range parsing or custom-function contracts changed.
- Cancellation/Office metadata: backend tests, UI production build, manifest validation, and a clearly labeled manual Excel/VBA check.
- Docker/runtime config: Docker build and local HTTP smoke tests only when Docker is available; never fabricate results when it is not.
- Pipeline YAML: syntax/repository review locally; queue/monitor only when authorized.

Record the exact command, exit result, and material warnings. Separate known warnings from failures.
