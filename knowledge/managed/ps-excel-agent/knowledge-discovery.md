# PS Excel Agent Knowledge Discovery

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base path: `C:\Repos\AI Knowledge\ps_excel_agent`
Discovery date: 2026-06-26

1. **Tech Stack**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.agent/planningspace.integration.excel.agent.csproj` targets `net9.0` and uses ASP.NET Core packages; `planningspace.integration.excel.ui/package.json` uses React 18, TypeScript, Webpack, Office.js, Redux Toolkit, Fluent UI, MUI, oidc-client-ts, and axios.
   - Suggested destination: `AGENTS.md`
   - Save recommendation: Yes

2. **Solution Layout**
   - Confidence: High
   - Evidence: `ps-excel-agent.sln` contains the API project and MSTest project; the UI is a separate Office add-in project under `planningspace.integration.excel.ui`.
   - Suggested destination: `docs`
   - Save recommendation: Yes

3. **Runtime Architecture**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.agent/Program.cs` serves API controllers plus static UI from `wwwroot`; `planningspace.integration.excel.agent/planningspace.integration.excel.agent.csproj` copies UI `dist` into backend `wwwroot` during post-build.
   - Suggested destination: `docs`
   - Save recommendation: Yes

4. **Excel Add-In Architecture**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.ui/manifest.xml` defines Excel taskpane, shared runtime, and custom functions; `planningspace.integration.excel.ui/webpack.config.js` bundles taskpane, auth pages, messagebox, and custom functions.
   - Suggested destination: `docs`
   - Save recommendation: Yes

5. **Authentication Flow**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.ui/src/session/userManagerPS.ts` configures OIDC against Planning Space Identity; `planningspace.integration.excel.ui/src/session/signIn.ts` opens the Office dialog; `planningspace.integration.excel.ui/src/authentication/callback-ps.ts` returns the authenticated user to the parent Office context.
   - Suggested destination: `docs`
   - Save recommendation: Yes

6. **Backend Auth Schemes**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.agent/Program.cs` enables JWT Bearer and API key auth under the `IPS Authenticated` policy; `planningspace.integration.excel.agent/Authentication/ApiKeyAuthenticationHandler.cs` validates Basic auth plus `PS-Tenant` by calling Planning Space `/users/current`.
   - Suggested destination: `adr`
   - Save recommendation: Yes

7. **Tenant and Runtime Config Pattern**
   - Confidence: High
   - Evidence: `planningspace.integration.excel.ui/src/environment.ts` reads tenant/clientId from URL or sessionStorage and merges `window.env`; `planningspace.integration.excel.agent/Program.cs` dynamically serves `env.js`.
   - Suggested destination: `AGENTS.md`
   - Save recommendation: Yes

8. **Database Access Patterns**
   - Confidence: Medium
   - Evidence: No EF/SQL/provider packages were found. Backend data access appears to go through `PlanningSpace.Integration.CalculationOrchestrator` and `IPlanningSpaceService`, for example `CalculationManager.cs` calls Planning Space APIs. Calculation state is held in memory via `ConcurrentDictionary`.
   - Suggested destination: `docs`
   - Save recommendation: Yes

9. **Planning Space Integrations**
   - Confidence: High
   - Evidence: `Program.cs` registers Planning Space service/controller abstractions; `appsettings.json` configures BaseUrl, Identity, retries, caching, throttling, defaults, and jobs.
   - Suggested destination: `docs`
   - Save recommendation: Yes

10. **License Server Integration**
    - Confidence: High
    - Evidence: `planningspace.integration.excel.ui/src/authentication/licenseManager.ts` uses `/licenseserver/{tenant}/api/v1/lease`; it acquires a Planning Space Economics license, refreshes every 2 minutes, and releases on sign-out.
    - Suggested destination: `docs`
    - Save recommendation: Yes

11. **Calculation Workflow**
    - Confidence: High
    - Evidence: `planningspace.integration.excel.ui/src/functions/functions.ts` submits calculation requests, polls progress, then fetches messages/results; `CalculationController.cs` exposes request/progress/results/messages endpoints; `CalculationManager.cs` creates async in-memory jobs.
    - Suggested destination: `docs`
    - Save recommendation: Yes

12. **Build and Test Commands**
    - Confidence: High
    - Evidence: `planningspace.integration.excel.ui/package.json` defines `npm run build`, `build:dev`, `dev-server`, `start:desktop`, `lint`, and `validate`; `azure-pipelines.yml` uses Node 18, `npm install`, `npm run build`, VSBuild, and VSTest.
    - Suggested destination: `AGENTS.md`
    - Save recommendation: Yes

13. **Local Testing Playbook**
    - Confidence: High
    - Evidence: `Test Files/how to test locally from build artifact.md` documents runtime prerequisites, manifest edits, trusted catalog setup, running the agent, and Excel custom function usage.
    - Suggested destination: `playbooks`
    - Save recommendation: Yes

14. **Coding Conventions**
    - Confidence: Medium
    - Evidence: C# nullable reference types and implicit usings are enabled in the API csproj; TypeScript compiler behavior is defined in `tsconfig.json`; Office add-in prettier/lint config is declared in UI `package.json`.
    - Suggested destination: `AGENTS.md`
    - Save recommendation: Yes

15. **Risky Areas**
    - Confidence: High
    - Evidence: In-memory job state/purge/throttling in `CalculationManager.cs`; token propagation through `ScopedContext` in `AuthHelper.cs`; direct custom function `ACCESS_TOKEN` in `functions.ts`; unauthenticated status endpoint in `StatusController.cs`.
    - Suggested destination: `memory`
    - Save recommendation: Ask

16. **Repeated Patterns**
    - Confidence: High
    - Evidence: API calls use bearer token plus `PS-Tenant` in `helpers.ts`; Redux slices follow compact `createSlice` patterns in `uiSlice.ts` and related feature slices; Excel logging centralizes through `logging.ts`.
    - Suggested destination: `AGENTS.md`
    - Save recommendation: Yes

17. **Current Worktree Caveat**
    - Confidence: High
    - Evidence: `git status --short` showed modified `ApiKeyAuthenticationHandler.cs`, `appsettings.json`, and `manifest.xml`, plus an untracked root `package-lock.json` during discovery.
    - Suggested destination: `memory`
    - Save recommendation: Ask
