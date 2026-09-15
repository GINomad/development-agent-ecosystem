# Auth Refresh Cold Start Summary

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base: `C:\Repos\AI Knowledge\ps_excel_agent`
Created: 2026-07-01

## Conversation Goal

Work centered on Planning Space Excel Agent authentication between the Office add-in UI and ASP.NET backend. The goal was to support `offline_access`, send refresh tokens to the backend, refresh expiring access tokens, and handle refresh-token rotation without breaking downstream Planning Space API calls.

## Key Decisions

1. UI requests `offline_access` in `userManagerPS.ts`.
2. UI sends these request headers from `helpers.ts`:
   - `Authorization: Bearer <access_token>`
   - `PS-Tenant: <tenant>`
   - `PS-Client-Id: <clientId>`
   - `PS-Refresh-Token: <refresh_token>` when present
3. Backend uses `PlanningSpaceTokenService` to check JWT expiration and refresh only when the access token is close to expiration.
4. Refresh request uses `PlanningSpace:Identity:Scope` from `appsettings.json` directly. Do not add a `??` fallback for scope.
5. Refresh-token rotation is supported by returning rotated tokens to the UI in response headers:
   - `PS-Access-Token`
   - `PS-Refresh-Token`
   - `PS-Expires-In`
6. Dev CORS exposes those response headers via `WithExposedHeaders` in `Program.cs`.
7. UI reads those headers in `callApi` and updates the stored `oidc-client-ts` user through `updateUserTokens.ts`.
8. Because access tokens may rotate too, backend returns both access token and refresh token. Returning only refresh token is not enough because future requests may fail `[Authorize]` before reaching controller code if UI keeps sending an expired access token.

## 2026-07-20 Parallel Refresh Follow-up

### Log Evidence

The analyzed Excel Agent log showed five interleaved calculation flows and 149 token endpoint calls:

- one `POST /identity/connect/token` returned `200`;
- 148 returned `400`;
- maximum observed concurrent refreshes: three;
- 161 Planning Space API responses all succeeded: 146 `200`, five `201`, and ten `202`;
- no `401`, `403`, `5xx`, or application exceptions were logged.

The first three refresh calls were started together. The first succeeded and rotated the token; the next two immediately failed with `400`. Another 146 refresh attempts started after that successful rotation and all failed.

This strongly indicates refresh-token reuse after rotation rather than an authority, client-id, or scope configuration error. The exact Identity error is not available because the backend currently returns `null` for a non-success token response without logging its safe OAuth error fields.

### Root Cause

Each Excel custom-function calculation acquired a `User` once and reused that object for its full submit/poll/messages/results lifecycle. Only the calculation whose refresh succeeded mutated its local `User`. Other parallel calculations continued sending their stale access/refresh token pair even after `oidc-client-ts` storage had been updated.

On the backend, every incoming request independently called the token endpoint. Rotation means only the first use of a refresh token succeeds. Failed refreshes silently fell back to the old access token, which remained usable while it was inside the pre-expiry refresh buffer.

### Implemented Parallel-Safe Shape

Backend, in `PlanningSpaceTokenService`:

1. Compute a SHA-256 key from `clientId + refreshToken`; do not store the raw refresh token as the coordination key.
2. Keep a `ConcurrentDictionary<string, Lazy<Task<AccessTokenResponse?>>>`.
3. Use `LazyThreadSafetyMode.ExecutionAndPublication` so all callers with the same old token pair await one Identity request.
4. Cache a successful rotated result for the configured refresh-buffer duration.
5. Return that same result to concurrent and slightly late callers carrying the old pair.
6. Remove failed operations so transient failures are retryable.
7. Keep coordination per token key, allowing different users/token pairs to refresh in parallel.

Do not replace this with only a semaphore. Serialization without cached result reuse still submits the consumed refresh token after the first caller completes.

UI, in `callApi`:

1. Call `userManagerPS.getUser()` immediately before building request headers.
2. Prefer that current stored user over the long-lived caller-provided `User`.
3. Pass the current user to `updateUserTokens` after the response.

The backend service must remain singleton for the in-memory coordination dictionaries to cover all requests in one Excel Agent process. A future multi-instance/server deployment would need distributed coordination.

### Verification Added

`PlanningSpaceTokenServiceTests.GetTokenAsyncSharesRotatedTokensBetweenParallelRequests` starts five concurrent requests with the same old token pair, holds the mocked Identity response until they are all able to overlap, and verifies:

- exactly one token endpoint call;
- the same new access token and refresh token for every request;
- `WasRefreshed = true` for every request;
- a late request with the old token pair reuses the same successful result.

Validation after implementation:

- `dotnet test ps-excel-agent.sln --no-restore`: 12 passed, 0 failed;
- `npm run build:dev`: successful.

## AsyncLocal / ScopedContext Lesson

`PlanningSpace.Integration.Utilities.ScopedContext.PsAccessToken` is backed by `AsyncLocal<string>`. Writing to it inside an async helper after an `await` caused downstream Planning Space calls not to see the token reliably.

Correct pattern:

```csharp
var tokenResult = await AuthHelper.GetTokenAsync(Request, tokenService);
AuthHelper.ApplyToken(Request, Response, tokenResult);
```

`GetTokenAsync` performs async retrieval/refresh and returns a result. `ApplyToken` synchronously applies the token to `ScopedContext` and response headers in the controller action flow.

## Current Important Files

Backend:
- `planningspace.integration.excel.agent/Authentication/IPlanningSpaceTokenService.cs`
- `planningspace.integration.excel.agent/Authentication/PlanningSpaceTokenService.cs`
- `planningspace.integration.excel.agent/Models/Authentication/AccessTokenResponse.cs`
- `planningspace.integration.excel.agent/Models/Authentication/TokenRefreshResult.cs`
- `planningspace.integration.excel.agent/V1/Helpers/AuthHelper.cs`
- `planningspace.integration.excel.agent/V1/Controllers/CalculationController.cs`
- `planningspace.integration.excel.agent/Program.cs`
- `planningspace.integration.excel.agent/appsettings.json`

UI:
- `planningspace.integration.excel.ui/src/session/userManagerPS.ts`
- `planningspace.integration.excel.ui/src/session/updateUserTokens.ts`
- `planningspace.integration.excel.ui/src/taskpane/utils/helpers.ts`

Knowledge files:
- `C:\Repos\AI Knowledge\ps_excel_agent\coding-style.md`
- `C:\Repos\AI Knowledge\ps_excel_agent\coding-knowledge.md`

## Coding Style Preferences From User

- All `if`, `else if`, and `else` statements must use braces, even for one-line bodies.
- Each class should have its own file.
- Classes should be public unless there is a specific approved reason to narrow visibility.
- Apply explicit access modifiers to methods based on usage.
- Do not declare methods inside other methods. Move helpers to class level.
- Use `using` directives instead of fully qualified type names in parameters.
- Do not add new controller-level `try`/`catch` wrappers without asking first. Preserve existing ones unless approved.
- When user introduces a new style rule, update `coding-style.md`.
- After any code or knowledge-base change, automatically open all task-related diffs in the user's IDE before handoff.

## Build Commands Used

Backend:

```powershell
dotnet build ps-excel-agent.sln
```

UI:

```powershell
cd planningspace.integration.excel.ui
npm run build:dev
```

Both builds passed after the auth refresh changes. Usual non-blocking warnings seen:
- NuGet credential provider warnings after successful .NET build.
- Browserslist data outdated warning after successful UI build.

## Last Suggested Commit Message

```text
Support rotated refresh tokens for Excel agent auth

- Return access, refresh, and expiry data from token refresh flow
- Add TokenRefreshResult and extend AccessTokenResponse
- Rename token service method to GetTokenAsync
- Apply refreshed tokens through AuthHelper.ApplyToken
- Send refreshed tokens back in response headers
- Expose token headers for dev CORS
- Update UI stored OIDC user when rotated tokens are returned
- Use configured Planning Space identity scope in refresh requests
```

## Caution For Future Work

Before editing, inspect current branch state because the user may update the branch between conversations. Do not assume the previous diff is still present. Always re-read the files above.

After editing, always open IDE diffs for all task-related changed files. Use an empty baseline for newly added files.
