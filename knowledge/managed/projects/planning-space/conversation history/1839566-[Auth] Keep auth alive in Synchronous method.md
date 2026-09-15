# 1839566 - [Auth] Keep auth alive in Synchronous method

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base: `C:\Repos\AI Knowledge\ps_excel_agent`
Created: 2026-07-16

## Goal

Requirement: keep an Excel session authenticated for the full duration of a synchronous calculation so long-running `ExecuteAndWait` calls do not fail halfway and force the analyst to re-authenticate and re-run.

Requested validation: check the proposed approach of extending `ACCESS_TOKEN()` to return access + refresh token to Excel, using those tokens from VBA when calling `CalculationController.ExecuteAndWait`, and then updating React/add-in tokens after Excel gets refreshed tokens back.

No repo code was changed during this investigation. This note captures feasibility and the recommended implementation shape.

## Current implementation observed

### Backend token refresh flow is already in place

`CalculationController.ExecuteAndWait` already does the same auth pre-flight as the async endpoints:

```csharp
var tokenResult = await AuthHelper.GetTokenAsync(Request, tokenService);
AuthHelper.ApplyToken(Request, Response, tokenResult);
return await calcManager.ExecuteCalculationAsync(data);
```

`PlanningSpaceTokenService.GetTokenAsync`:
- extracts the bearer access token from `Authorization`;
- checks JWT expiry with a configurable buffer, default 5 minutes;
- when near expiry, requires both request headers:
  - `PS-Refresh-Token`
  - `PS-Client-Id`
- calls `{authority}/connect/token` with `grant_type=refresh_token`;
- returns refreshed access token, optional rotated refresh token, and `expires_in`.

`AuthHelper.ApplyToken`:
- sets `ScopedContext.PsAccessToken` to the effective token used by downstream Planning Space calls;
- when refresh happened, returns these response headers:
  - `PS-Access-Token`
  - `PS-Refresh-Token`
  - `PS-Expires-In`

### React/custom-function API path already handles rotated tokens

`planningspace.integration.excel.ui/src/taskpane/utils/helpers.ts` sends:
- `Authorization: Bearer <access_token>`
- `PS-Tenant`
- `PS-Client-Id`
- `PS-Refresh-Token` when present

After every response, `callApi` reads `PS-Access-Token`, `PS-Refresh-Token`, and `PS-Expires-In`, then calls `updateUserTokens(...)`.

`updateUserTokens.ts` mutates the in-memory `User` and persists a new `oidc-client-ts` `User` via `userManagerPS.storeUser(...)`.

So the regular React/custom-function path already supports pre-flight refresh and token rotation.

### Current `ACCESS_TOKEN()` is access-token only

`planningspace.integration.excel.ui/src/functions/functions.ts` currently exposes:

```ts
export async function ACCESS_TOKEN(): Promise<string> {
  const user = await userManagerPS.getUser();
  if (!user || !user.access_token || user.expired) {
    throw new Error("Authentication is required. Please open the add-in and log in.");
  }
  return user.access_token;
}
```

`functions.json` declares it as a string-returning custom function.

### Attached VBA synchronous path currently bypasses refresh support

The attached macro calls:

```vb
http.Open "POST", url, False
http.setRequestHeader "Content-Type", "application/json"
http.setRequestHeader "Authorization", "Bearer " & token
http.setRequestHeader "PS-Tenant", "atlantis"
http.Send payload
```

It does not send:
- `PS-Refresh-Token`
- `PS-Client-Id`

It also does not read response headers:
- `PS-Access-Token`
- `PS-Refresh-Token`
- `PS-Expires-In`

Therefore, for this VBA `ExecuteAndWait` path, backend refresh currently cannot happen unless the token is still valid enough at request start.

## Feasibility of the proposed solution

### Partly feasible, but not sufficient as stated

Extending `ACCESS_TOKEN()` to return access + refresh token + client id would allow the VBA request to send the required refresh headers. That would satisfy the pre-flight freshness check if the access token is near expiry before `ExecuteAndWait` starts.

However, this alone does not fully satisfy the mid-call refresh requirement.

Reason: `ExecuteAndWait` is one long synchronous HTTP request. Once VBA sends the request, the original HTTP headers are fixed. If the access token expires while `calcManager.ExecuteCalculationAsync(data)` is still running, the backend cannot ask VBA for a new token during that same request. Updating React after the response is also too late for Planning Space calls that already failed inside the running calculation.

### What currently works

If the token is near expiry before `ExecuteAndWait` starts and VBA sends `PS-Refresh-Token` + `PS-Client-Id`, the backend can refresh once at the beginning and run the calculation with the refreshed access token in `ScopedContext.PsAccessToken`.

This likely covers many long-running calls if the new access token lifetime is longer than the calculation duration.

### What does not work yet

If the refreshed access token expires during the single synchronous request, there is no current mechanism to refresh again mid-execution. `PlanningSpaceTokenService` only runs at controller entry. Downstream Planning Space service calls use `ScopedContext.PsAccessToken`; they do not appear to have a retry/refresh hook when a Planning Space API call receives 401/expired-token.

Also, if refresh fails today, `PlanningSpaceTokenService` returns the original access token and does not distinguish refresh failure from "no refresh attempted". That means a revoked/expired refresh token can still lead to later generic failures instead of a clean re-authentication response.

## Recommended implementation shape

### 1. Add a dedicated token bundle custom function, do not silently change `ACCESS_TOKEN()`

Changing `ACCESS_TOKEN()` from returning a raw string to returning JSON would break existing formulas/macros that expect just a bearer token.

Safer option:
- keep `ACCESS_TOKEN()` unchanged for compatibility;
- add a new custom function such as `AUTH_TOKENS()` or `PSEAUTHINFO()` returning a JSON string:

```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "clientId": "...",
  "expiresAt": 1234567890,
  "tenant": "atlantis"
}
```

The VBA macro can parse this JSON and send:
- `Authorization: Bearer <accessToken>`
- `PS-Refresh-Token: <refreshToken>`
- `PS-Client-Id: <clientId>`
- `PS-Tenant: <tenant>`

Security note: exposing the refresh token into worksheet/VBA space increases token exposure. Prefer keeping it transient in a hidden helper cell or passing it directly into the macro flow; avoid leaving refresh tokens visible in worksheets or logs.

### 2. Return refreshed tokens from `CallExecuteandwait`

The VBA function should read response headers after `http.Send payload`:

- `http.getResponseHeader("PS-Access-Token")`
- `http.getResponseHeader("PS-Refresh-Token")`
- `http.getResponseHeader("PS-Expires-In")`

But VBA alone cannot directly update the React `oidc-client-ts` store. A separate bridge is needed.

Possible bridge options:
1. Add a custom function or command that accepts refreshed token data and calls `updateUserTokens(...)` in the add-in context.
2. Prefer avoiding VBA-managed token updates by moving the synchronous call into the custom function/TypeScript layer, where `callApi` already updates tokens.
3. If keeping VBA as the HTTP caller, return response JSON plus token headers to a helper cell, then invoke an Office custom function that stores tokens. This is awkward and risks exposing tokens in cells.

Best engineering direction: keep token handling inside TypeScript/add-in code whenever possible.

### 3. For true mid-call refresh, backend needs refresh capability below the controller

To fully satisfy "Silent Mid-Call Token Refresh", pre-flight refresh is not enough. The refresh mechanism must be available during downstream Planning Space API calls.

Likely backend change:
- carry refresh context for the request: access token, refresh token, client id, tenant;
- before each Planning Space API request, check whether the current access token is near expiry and refresh if needed; or
- on a Planning Space 401/expired-token response, refresh once and retry the failed Planning Space call;
- update `ScopedContext.PsAccessToken` after successful mid-call refresh;
- return rotated tokens in the final `ExecuteAndWait` response headers.

This probably belongs in the Planning Space HTTP/service layer rather than only in `CalculationController`, because `ExecuteCalculationAsync` performs many downstream calls after controller entry.

Open design question: confirm where `PlanningSpace.Integration.Utilities.ScopedContext.PsAccessToken` is read by the shared Planning Space service and whether that shared service can be extended to call a refresh provider/retry handler.

### 4. Refresh failure must become explicit

Current `PlanningSpaceTokenService.RefreshAccessTokenAsync` returns `null` on failed refresh and `GetTokenAsync` falls back to the old access token. That behavior hides the distinction between:
- token not close to expiry;
- refresh headers missing;
- refresh attempted but failed because refresh token is expired/revoked.

Requirement needs explicit handling:
- if refresh is required and refresh token/client id is missing: return 401 with a clear re-authentication message;
- if refresh is attempted and token endpoint rejects it: return 401 with a clear re-authentication message;
- for mid-call refresh failure: abort calculation cleanly and return a `CalculationCompleteResponseModel`/HTTP response that Excel can show as re-authentication required rather than generic calculation failure.

Avoid adding broad controller `try/catch` unless approved; prefer typed result/exception from auth service and narrow handling at auth boundary.

## Requirement mapping

| Requirement | Current state | Gap |
|---|---|---|
| Token freshness check before synchronous call | Backend supports it; `ExecuteAndWait` calls `GetTokenAsync` | VBA must send `PS-Refresh-Token` and `PS-Client-Id`; `ACCESS_TOKEN()` only returns access token today |
| Silent mid-call token refresh | Not fully supported for a single long `ExecuteAndWait` request | Need refresh/retry in Planning Space service layer during downstream API calls |
| Refresh failure handling | Not explicit | Need distinguish refresh failure and return clean re-auth prompt/401 or auth-specific calculation status |

## Minimal implementation path for Size S

If the intended Size S scope is pragmatic rather than perfect:

1. Add new `PSEAUTHINFO()` custom function returning JSON token bundle.
2. Update `functions.json` metadata.
3. Update VBA `CallExecuteandwait` to accept token bundle or separate access/refresh/client id args and send the missing headers.
4. Read refreshed token response headers from VBA.
5. Add a small add-in-side function/bridge to persist refreshed tokens, or document that token persistence only updates after the next React/custom-function API call.
6. Improve backend refresh failure reporting when refresh is required but impossible.

This covers pre-flight refresh and clear refresh-failure handling, but it should be documented as not guaranteeing refresh if a single synchronous calculation outlives the refreshed access token.

## Recommended implementation path for complete requirement

1. Add token bundle support for the VBA synchronous caller.
2. Extend backend auth result to represent refresh failure explicitly.
3. Add request-scoped token refresh context that includes refresh token/client id.
4. Move/duplicate expiry check into the Planning Space outbound HTTP layer so long-running `ExecuteAndWait` can refresh between downstream API calls.
5. Add one retry on 401 from Planning Space after successful refresh.
6. Return final rotated tokens in `ExecuteAndWait` response headers and update the add-in token store.
7. Add tests around:
   - pre-flight refresh with token rotation;
   - missing refresh token when access token is near expiry;
   - failed refresh token response;
   - downstream 401 -> refresh -> retry success;
   - downstream 401 -> refresh failure -> re-authentication response.

## Files inspected

Backend:
- `planningspace.integration.excel.agent/V1/Controllers/CalculationController.cs`
- `planningspace.integration.excel.agent/Authentication/PlanningSpaceTokenService.cs`
- `planningspace.integration.excel.agent/V1/Helpers/AuthHelper.cs`
- `planningspace.integration.excel.agent/Models/Authentication/TokenRefreshResult.cs`

UI:
- `planningspace.integration.excel.ui/src/functions/functions.ts`
- `planningspace.integration.excel.ui/src/functions/functions.json`
- `planningspace.integration.excel.ui/src/taskpane/utils/helpers.ts`
- `planningspace.integration.excel.ui/src/session/updateUserTokens.ts`
- `planningspace.integration.excel.ui/src/session/userManagerPS.ts`

Attached VBA:
- `CallExecuteandwait` sends only bearer token and tenant today.
- `PSECALCULATEANDWAIT` builds JSON, calls `CallExecuteandwait`, and parses response.

## Bottom line

The proposed `ACCESS_TOKEN()` expansion is a useful building block only if it gives VBA the refresh token and client id, but it should probably be a new token-bundle function for compatibility. It solves pre-flight refresh for the synchronous VBA call, not true mid-call refresh. True mid-call refresh requires backend refresh/retry support inside the downstream Planning Space call layer, because the synchronous HTTP request cannot change its original Authorization header after it has started.
---

## 2026-07-16 Backend implementation draft

User clarification: `PlanningSpaceTokenService` already exists and should remain the central component for token mechanics. The missing piece is not a new token service; the missing piece is making the existing service available after controller entry, while downstream Planning Space calls are running inside `ExecuteAndWait`.

### Design principle

Keep `PlanningSpaceTokenService` responsible for:
- parsing/checking access-token expiry;
- refreshing with refresh token + client id;
- returning rotated access/refresh tokens and expiry;
- reporting refresh failure explicitly.

Add:
- request-scoped token context via `AsyncLocal`;
- a refresh-aware wrapper/decorator around `IPlanningSpaceService`;
- final response-header emission for rotated tokens refreshed mid-call.

This keeps auth mechanics centralized while allowing true mid-call refresh.

### New enum: `Models/Authentication/PlanningSpaceTokenStatus.cs`

```csharp
namespace planningspace.integration.excel.agent.Models.Authentication
{
    public enum PlanningSpaceTokenStatus
    {
        NotNeeded,
        Refreshed,
        MissingRefreshData,
        RefreshFailed
    }
}
```

### Extend `Models/Authentication/TokenRefreshResult.cs`

```csharp
namespace planningspace.integration.excel.agent.Models.Authentication
{
    public class TokenRefreshResult
    {
        public string? AccessToken { get; set; }
        public string? RefreshToken { get; set; }
        public int? ExpiresIn { get; set; }
        public bool WasRefreshed { get; set; }
        public PlanningSpaceTokenStatus Status { get; set; } = PlanningSpaceTokenStatus.NotNeeded;

        public bool RequiresReauthentication =>
            Status == PlanningSpaceTokenStatus.MissingRefreshData ||
            Status == PlanningSpaceTokenStatus.RefreshFailed;
    }
}
```

### New request context: `Authentication/PlanningSpaceTokenContext.cs`

```csharp
namespace planningspace.integration.excel.agent.Authentication
{
    public class PlanningSpaceTokenContext
    {
        public string? AccessToken { get; set; }
        public string? RefreshToken { get; set; }
        public string? ClientId { get; set; }
        public string? Tenant { get; set; }
        public bool WasRefreshed { get; set; }
        public int? ExpiresIn { get; set; }
    }
}
```

### New accessor: `Authentication/PlanningSpaceTokenContextAccessor.cs`

```csharp
namespace planningspace.integration.excel.agent.Authentication
{
    public class PlanningSpaceTokenContextAccessor
    {
        private readonly AsyncLocal<PlanningSpaceTokenContext?> _current = new();

        public PlanningSpaceTokenContext? Current
        {
            get => _current.Value;
            set => _current.Value = value;
        }
    }
}
```

### Extend `Authentication/IPlanningSpaceTokenService.cs`

```csharp
using Microsoft.AspNetCore.Http;
using planningspace.integration.excel.agent.Models.Authentication;

namespace planningspace.integration.excel.agent.Authentication
{
    public interface IPlanningSpaceTokenService
    {
        Task<TokenRefreshResult> GetTokenAsync(HttpRequest request);
        Task<TokenRefreshResult> RefreshIfNeededAsync(PlanningSpaceTokenContext context);
        Task<TokenRefreshResult> RefreshAsync(PlanningSpaceTokenContext context);
    }
}
```

### `PlanningSpaceTokenService` draft changes

Keep `GetTokenAsync(HttpRequest request)` for controller-entry compatibility, but convert the request into a `PlanningSpaceTokenContext` and delegate to context-based methods.

```csharp
public async Task<TokenRefreshResult> GetTokenAsync(HttpRequest request)
{
    var accessToken = ExtractBearerToken(request);
    var refreshToken = GetHeaderValue(request, RefreshTokenHeader);
    var clientId = GetHeaderValue(request, ClientIdHeader);

    var context = new PlanningSpaceTokenContext
    {
        AccessToken = accessToken,
        RefreshToken = refreshToken,
        ClientId = clientId,
        Tenant = GetHeaderValue(request, "PS-Tenant"),
    };

    return await RefreshIfNeededAsync(context);
}

public async Task<TokenRefreshResult> RefreshIfNeededAsync(PlanningSpaceTokenContext context)
{
    if (string.IsNullOrWhiteSpace(context.AccessToken))
    {
        return new TokenRefreshResult();
    }

    if (!IsExpiringSoon(context.AccessToken))
    {
        return new TokenRefreshResult
        {
            AccessToken = context.AccessToken,
            Status = PlanningSpaceTokenStatus.NotNeeded,
        };
    }

    return await RefreshAsync(context);
}

public async Task<TokenRefreshResult> RefreshAsync(PlanningSpaceTokenContext context)
{
    if (string.IsNullOrWhiteSpace(context.RefreshToken) ||
        string.IsNullOrWhiteSpace(context.ClientId))
    {
        return new TokenRefreshResult
        {
            AccessToken = context.AccessToken,
            Status = PlanningSpaceTokenStatus.MissingRefreshData,
        };
    }

    var tokenResponse = await RefreshAccessTokenAsync(context.RefreshToken, context.ClientId);
    if (string.IsNullOrWhiteSpace(tokenResponse?.AccessToken))
    {
        return new TokenRefreshResult
        {
            AccessToken = context.AccessToken,
            Status = PlanningSpaceTokenStatus.RefreshFailed,
        };
    }

    context.AccessToken = tokenResponse.AccessToken;
    context.RefreshToken = tokenResponse.RefreshToken ?? context.RefreshToken;
    context.ExpiresIn = tokenResponse.ExpiresIn;
    context.WasRefreshed = true;

    return new TokenRefreshResult
    {
        AccessToken = context.AccessToken,
        RefreshToken = tokenResponse.RefreshToken,
        ExpiresIn = tokenResponse.ExpiresIn,
        WasRefreshed = true,
        Status = PlanningSpaceTokenStatus.Refreshed,
    };
}
```

Important behavior change: when refresh is required but impossible, do not silently fall back to the old access token. Return `MissingRefreshData` or `RefreshFailed` so callers can return a clear re-authentication response.

### New exception: `Authentication/ReauthenticationRequiredException.cs`

```csharp
namespace planningspace.integration.excel.agent.Authentication
{
    public class ReauthenticationRequiredException : Exception
    {
        public ReauthenticationRequiredException()
            : base("Authentication is required. Please open the add-in and log in again.")
        {
        }
    }
}
```

### Update `V1/Helpers/AuthHelper.cs`

`AuthHelper.ApplyToken` should both apply the effective access token to `ScopedContext.PsAccessToken` and initialize request-scoped token context for downstream refresh.

```csharp
public static void ApplyToken(
    HttpRequest request,
    HttpResponse response,
    TokenRefreshResult tokenResult,
    PlanningSpaceTokenContextAccessor tokenContextAccessor)
{
    if (request == null)
    {
        return;
    }

    var tenant = request.Headers.TryGetValue("PS-Tenant", out var tenantHeader)
        ? tenantHeader.ToString().Trim()
        : null;

    var refreshToken = request.Headers.TryGetValue("PS-Refresh-Token", out var refreshHeader)
        ? refreshHeader.ToString().Trim()
        : null;

    var clientId = request.Headers.TryGetValue("PS-Client-Id", out var clientHeader)
        ? clientHeader.ToString().Trim()
        : null;

    ScopedContext.PsAccessToken = tokenResult.AccessToken;

    tokenContextAccessor.Current = new PlanningSpaceTokenContext
    {
        AccessToken = tokenResult.AccessToken,
        RefreshToken = tokenResult.RefreshToken ?? refreshToken,
        ClientId = clientId,
        Tenant = tenant,
        WasRefreshed = tokenResult.WasRefreshed,
        ExpiresIn = tokenResult.ExpiresIn,
    };

    ApplyResponseHeaders(response, tokenResult);
}

public static void ApplyResponseHeaders(HttpResponse response, TokenRefreshResult tokenResult)
{
    if (!tokenResult.WasRefreshed)
    {
        return;
    }

    if (!string.IsNullOrWhiteSpace(tokenResult.AccessToken))
    {
        response.Headers["PS-Access-Token"] = tokenResult.AccessToken;
    }

    if (!string.IsNullOrWhiteSpace(tokenResult.RefreshToken))
    {
        response.Headers["PS-Refresh-Token"] = tokenResult.RefreshToken;
    }

    if (tokenResult.ExpiresIn.HasValue)
    {
        response.Headers["PS-Expires-In"] = tokenResult.ExpiresIn.Value.ToString();
    }
}
```

All controller methods that currently call `AuthHelper.ApplyToken(Request, Response, tokenResult)` need to pass `tokenContextAccessor`.

### New wrapper: `Authentication/RefreshingPlanningSpaceService.cs`

This wrapper enables true mid-call refresh because `CalculationManager` and orchestrator controllers already use `IPlanningSpaceService` for downstream Planning Space calls.

```csharp
using System.Net;
using planningspace.integration.excel.agent.Models.Authentication;
using PlanningSpace.Integration.PlanningSpaceClient;
using PlanningSpace.Integration.Utilities;

namespace planningspace.integration.excel.agent.Authentication
{
    public class RefreshingPlanningSpaceService : IPlanningSpaceService
    {
        private readonly PlanningSpaceService _inner;
        private readonly IPlanningSpaceTokenService _tokenService;
        private readonly PlanningSpaceTokenContextAccessor _tokenContextAccessor;

        public RefreshingPlanningSpaceService(
            PlanningSpaceService inner,
            IPlanningSpaceTokenService tokenService,
            PlanningSpaceTokenContextAccessor tokenContextAccessor)
        {
            _inner = inner;
            _tokenService = tokenService;
            _tokenContextAccessor = tokenContextAccessor;
        }

        public async Task<HttpResponseMessage> RequestAsync(
            HttpMethod method,
            string url,
            string? accept,
            object? payload)
        {
            await RefreshBeforeRequestAsync();

            var response = await _inner.RequestAsync(method, url, accept, payload);
            if (response.StatusCode != HttpStatusCode.Unauthorized)
            {
                return response;
            }

            response.Dispose();

            await ForceRefreshAsync();
            return await _inner.RequestAsync(method, url, accept, payload);
        }

        private async Task RefreshBeforeRequestAsync()
        {
            var context = _tokenContextAccessor.Current;
            if (context == null)
            {
                return;
            }

            var result = await _tokenService.RefreshIfNeededAsync(context);
            ApplyRefreshResult(context, result);
        }

        private async Task ForceRefreshAsync()
        {
            var context = _tokenContextAccessor.Current;
            if (context == null)
            {
                throw new ReauthenticationRequiredException();
            }

            var result = await _tokenService.RefreshAsync(context);
            ApplyRefreshResult(context, result);
        }

        private static void ApplyRefreshResult(
            PlanningSpaceTokenContext context,
            TokenRefreshResult result)
        {
            if (result.RequiresReauthentication)
            {
                throw new ReauthenticationRequiredException();
            }

            if (!string.IsNullOrWhiteSpace(result.AccessToken))
            {
                context.AccessToken = result.AccessToken;
                ScopedContext.PsAccessToken = result.AccessToken;
            }

            if (!string.IsNullOrWhiteSpace(result.RefreshToken))
            {
                context.RefreshToken = result.RefreshToken;
            }

            if (result.ExpiresIn.HasValue)
            {
                context.ExpiresIn = result.ExpiresIn;
            }

            context.WasRefreshed = context.WasRefreshed || result.WasRefreshed;
        }
    }
}
```

Caveat to verify before implementation: confirm `PlanningSpaceService` is public and constructible from DI. If it cannot be injected directly as concrete type, register a named inner adapter or create a local wrapper pattern compatible with the package.

### `Program.cs` service registrations

Replace:

```csharp
builder.Services.AddSingleton<IPlanningSpaceService, PlanningSpaceService>();
```

With:

```csharp
builder.Services.AddSingleton<PlanningSpaceService>();
builder.Services.AddSingleton<IPlanningSpaceService, RefreshingPlanningSpaceService>();
builder.Services.AddSingleton<PlanningSpaceTokenContextAccessor>();
builder.Services.AddSingleton<IPlanningSpaceTokenService, PlanningSpaceTokenService>();
```

Keep only one `IPlanningSpaceTokenService` registration.

### `Program.cs` middleware for final rotated-token headers

If refresh happens in the middle of `ExecuteAndWait`, controller-entry `AuthHelper.ApplyToken` cannot know the final token values. Add middleware that emits final token headers right before response starts.

Place after `app.UseAuthorization()` and before `app.MapControllers()`.

```csharp
app.Use(async (context, next) =>
{
    var tokenContextAccessor = context.RequestServices
        .GetRequiredService<PlanningSpaceTokenContextAccessor>();

    context.Response.OnStarting(() =>
    {
        var tokenContext = tokenContextAccessor.Current;
        if (tokenContext?.WasRefreshed == true)
        {
            if (!string.IsNullOrWhiteSpace(tokenContext.AccessToken))
            {
                context.Response.Headers["PS-Access-Token"] = tokenContext.AccessToken;
            }

            if (!string.IsNullOrWhiteSpace(tokenContext.RefreshToken))
            {
                context.Response.Headers["PS-Refresh-Token"] = tokenContext.RefreshToken;
            }

            if (tokenContext.ExpiresIn.HasValue)
            {
                context.Response.Headers["PS-Expires-In"] = tokenContext.ExpiresIn.Value.ToString();
            }
        }

        return Task.CompletedTask;
    });

    await next();
});
```

### `CalculationController` draft

Constructor gains `PlanningSpaceTokenContextAccessor`:

```csharp
public class CalculationController(
    ICalculationManager calcManager,
    IPlanningSpaceTokenService tokenService,
    PlanningSpaceTokenContextAccessor tokenContextAccessor) : ControllerBase
```

`ExecuteAndWait`:

```csharp
[HttpPost("ExecuteAndWait")]
public async Task<ActionResult<CalculationCompleteResponseModel>> ExecuteAndWait([FromBody] ExcelInputModel data)
{
    var tokenResult = await AuthHelper.GetTokenAsync(Request, tokenService);

    if (tokenResult.RequiresReauthentication)
    {
        return Unauthorized("Authentication is required. Please open the add-in and log in again.");
    }

    AuthHelper.ApplyToken(Request, Response, tokenResult, tokenContextAccessor);

    try
    {
        return await calcManager.ExecuteCalculationAsync(data);
    }
    catch (ReauthenticationRequiredException ex)
    {
        return Unauthorized(ex.Message);
    }
    catch (InputValidationException ex)
    {
        return BadRequest(ex.Errors);
    }
}
```

The same `RequiresReauthentication` check and updated `ApplyToken` call should be applied to other calculation endpoints. If this story is scoped only to synchronous mode, `ExecuteAndWait` is the must-have endpoint, but consistency argues for updating all methods in `CalculationController`.

### What this backend draft satisfies

- Pre-flight refresh before `ExecuteAndWait`.
- Silent refresh before downstream Planning Space calls during a long synchronous calculation.
- One retry after downstream Planning Space returns `401 Unauthorized`.
- Clean re-authentication response if refresh token is expired/revoked/missing.
- Rotated access/refresh token propagation back to Excel/React via response headers even when refresh happened mid-call.

### Still required from Excel/VBA/UI

Backend cannot refresh if the caller only sends a bearer token. The synchronous VBA path must send:

- `Authorization: Bearer <accessToken>`
- `PS-Refresh-Token: <refreshToken>`
- `PS-Client-Id: <clientId>`
- `PS-Tenant: <tenant>`

Recommended UI change remains: keep existing `ACCESS_TOKEN()` unchanged and add a new token-bundle custom function such as `PSEAUTHINFO()` to avoid breaking existing formulas/macros.