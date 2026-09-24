# PlanningSpace iframe spreadsheet integration

## Verified repository evidence

Observed against the local PlanningSpace source snapshot at `db7f87c7209b5897bba21df7d98a0e0081b58cef` on 2026-09-24. The working tree was dirty, so this document records the directly inspected files and their stated limits rather than claiming a clean-release baseline.

PlanningSpace already displays spreadsheet/report content in an Angular iframe. `ReportViewComponent` loads `spreadsheet-loader.html`; after iframe load it posts a bearer token, report identifiers/path, and API base to `window.location.origin`. The matching template creates the `spreadsheetFrame` iframe.

`spreadsheet-loader.js` rejects `postMessage` events whose `origin` differs from `window.location.origin`, then fetches the requested report with an `Authorization: Bearer` header. The inspected listener does not check `event.source === window.parent`.

The ASP.NET Core host configures CORS from `IAspNetSettingsProvider.AllowedOrigins`. `ConfigureCrossOriginResourceSharing` allows credentials, methods, and headers, then accepts only origins present in that allowlist using ordinal-ignore-case comparison. The static-content CSP is configurable; its source default contains `frame-ancestors 'self' app.pendo.io` and `frame-src 'self' app.pendo.io`, while runtime settings can override that default.

Specific TenantAuthentication MVC actions in Account, Consent, and Grants use `ValidateAntiForgeryToken`. This evidence does not establish global antiforgery coverage for every ASP.NET Core API or for a future spreadsheet application.

## Integration decision and limit

Hosting a DevExpress Spreadsheet ASP.NET Core application separately and embedding it from PlanningSpace Angular in an iframe is consistent with the inspected PlanningSpace pattern and the delivered DevExpress Spreadsheet POC. Hosting through IPS at the same origin fits the default CSP. Deployed compatibility still requires IPS validation because runtime CSP/CORS values, proxy routing, authentication cookies and SameSite policy, and DevExpress callback paths are deployment-specific.

Manager-facing summary: Based on the PlanningSpace codebase and our POC, we can use an iframe to host the DevExpress Spreadsheet ASP.NET Core application within Angular. PlanningSpace already uses an iframe for the read-only spreadsheet view. The final compatibility results will be confirmed once the solution is hosted and tested in IPS.

## Evidence

- `Web/economics/src/app/report/resultset-view/report-view/report-view.component.ts`, lines 34-68, and `report-view.component.html`
- `Web/economics/src/spreadsheet-loader.js`
- `IPS/Palantir.IPS.AspNetCore.Extensions/Application/CorsConfigurationExtensions.cs`
- `IPS/Palantir.IPS.AspNetCore.Hosting/Host/AspNetCoreAppStartupBase.cs`, around line 194
- `IPS/Palantir.IPS.Common/Settings/CoreSettingDefinitions.cs`, around line 547
- `IPS/Palantir.IPS.AspNetCore.Extensions/Application/StaticContentConfigurationExtensions.cs`, around line 75
- User comment `115f2a2fe6ce4242bccbc40312692611`, whose supplied evidence was directly checked during final publication
