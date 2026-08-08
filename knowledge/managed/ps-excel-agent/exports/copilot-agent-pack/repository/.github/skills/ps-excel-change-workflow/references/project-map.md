# Project map

## Runtime boundaries

- `planningspace.integration.excel.ui`: Excel task pane and custom-functions runtime. React/TypeScript/Webpack/Office.js/OIDC.
- `planningspace.integration.excel.agent`: ASP.NET Core API and static UI host. Current source targets .NET 10.
- `planningspace.integration.excel.agentTests`: MSTest/Moq backend tests.
- `Manifests` and UI `manifest.xml`: Office add-in registration and environment URLs.
- `Test Files`: manual workbook fixtures and local-testing notes.

The backend build copies UI `dist` into `wwwroot` and removes copied `env.js` so runtime configuration can be emitted dynamically by ASP.NET. Verify the current `.csproj` and `Program.cs` rather than assuming middleware precedence.

## Important paths

Authentication:

- `planningspace.integration.excel.ui/src/session/userManagerPS.ts`
- `planningspace.integration.excel.ui/src/session/updateUserTokens.ts`
- `planningspace.integration.excel.ui/src/taskpane/utils/helpers.ts`
- `planningspace.integration.excel.agent/Authentication`
- `planningspace.integration.excel.agent/V1/Helpers/AuthHelper.cs`

Calculations and scenarios:

- `planningspace.integration.excel.ui/src/functions/functions.ts`
- `planningspace.integration.excel.ui/src/functions/functions.json`
- `planningspace.integration.excel.agent/CalculationManager.cs`
- `planningspace.integration.excel.agent/Helpers/ScenarioHelper.cs`
- `planningspace.integration.excel.agent/Helpers/ExcelInputRowHelper.cs`
- `planningspace.integration.excel.agent/Models/Internal/ScenarioPathParser.cs`
- `planningspace.integration.excel.agent/V1/Controllers/CalculationController.cs`

Configuration and delivery:

- `planningspace.integration.excel.agent/Program.cs`
- `planningspace.integration.excel.agent/appsettings*.json`
- `planningspace.integration.excel.ui/src/environment.ts`
- `planningspace.integration.excel.ui/env*.js`
- `Dockerfile`
- `azure-pipelines.yml`
- `azure-pipeline-docker.yml`

## Architectural cautions

- Calculation jobs are held in memory. Concurrency, cleanup, cancellation, and multi-instance behavior require explicit reasoning.
- Planning Space access is primarily through orchestration/service libraries, not a local relational data layer in this repository.
- Excel custom functions can outlive the OIDC user object captured at their start.
- UI/API DTO changes often require synchronized TypeScript parsing, C# models, validation, custom-function metadata, and tests.
- Historical knowledge may describe a previous target framework or abandoned prototype. Current source wins.
