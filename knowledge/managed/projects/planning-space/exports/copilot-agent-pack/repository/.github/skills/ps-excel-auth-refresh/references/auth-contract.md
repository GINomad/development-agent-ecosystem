# Authentication contract and known failure modes

## End-to-end flow

The UI requests `offline_access` and normally sends:

- `Authorization: Bearer <access token>`
- `PS-Tenant`
- `PS-Client-Id`
- `PS-Refresh-Token` when available

The backend resolves or refreshes the token before Planning Space calls. When rotation occurs, it returns:

- `PS-Access-Token`
- `PS-Refresh-Token`
- `PS-Expires-In`

The UI reads these response headers and updates the stored `oidc-client-ts` user. Development CORS must expose the headers when the browser crosses origins.

Verify header names and configuration in current source before changing them.

## Parallel rotating refresh tokens

Multiple Excel calculations can send the same old token pair concurrently. With rotating refresh tokens, only the first Identity request may succeed; later reuse can return `400`.

The established single-process backend pattern is:

1. Derive a SHA-256 coordination key from `clientId + refreshToken`; never retain the raw token as a key.
2. Store a `Lazy<Task<AccessTokenResponse?>>` per key in a concurrent dictionary.
3. Use `LazyThreadSafetyMode.ExecutionAndPublication` so one Identity request executes.
4. Return the same rotated result to all concurrent callers.
5. Retain successful results for the refresh-buffer duration so slightly late requests with the old pair recover.
6. Remove failed operations so a transient failure is retryable.
7. Keep the service singleton for process-wide coordination.

A semaphore without successful-result reuse is insufficient: waiters still submit the consumed refresh token. Coordination is per token key, not global. Multi-instance deployments require distributed coordination or a different rotation contract.

On the UI, long-running calculations must call `userManagerPS.getUser()` immediately before building each request and pass that current user to `updateUserTokens`. Do not rely solely on a user object captured when the calculation began.

## AsyncLocal / ScopedContext

`ScopedContext.PsAccessToken` is backed by `AsyncLocal`. Resolve tokens asynchronously, then apply the resolved token synchronously in the controller execution flow:

```csharp
var tokenResult = await AuthHelper.GetTokenAsync(Request, tokenService);
AuthHelper.ApplyToken(Request, Response, tokenResult);
```

Avoid assigning downstream-required `ScopedContext` values inside an async helper after an `await`.

## Required verification

The concurrency test should prove overlap and assert:

- one token endpoint call for the same old pair;
- every caller receives the same rotated access/refresh pair;
- every result reports refresh;
- a late caller with the old pair reuses the successful result.

Also build the UI because request-header freshness and response-token persistence are part of the same contract.
