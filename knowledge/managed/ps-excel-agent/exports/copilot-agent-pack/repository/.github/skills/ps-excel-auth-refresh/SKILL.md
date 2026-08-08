---
name: ps-excel-auth-refresh
description: Diagnose or change Planning Space authentication, OIDC sessions, access/refresh-token propagation, token rotation, AsyncLocal ScopedContext behavior, auth headers, and auth concurrency in ps-excel-agent. Use whenever work touches userManagerPS, updateUserTokens, callApi, AuthHelper, PlanningSpaceTokenService, auth middleware, CORS token headers, or expiring-token failures.
---

# PS Excel authentication and token refresh

1. Read [references/auth-contract.md](references/auth-contract.md).
2. Re-read the current UI helper, token service, auth helper, controller, middleware, configuration, and focused tests before editing.
3. Trace both request and response token flow. A change is incomplete if only one side understands rotated tokens.
4. Preserve per-token refresh coalescing and result reuse unless evidence proves the contract changed.
5. Keep `ScopedContext` application synchronous in the controller flow after async token resolution.
6. Add deterministic concurrency tests for refresh coordination changes.
7. Never log or persist plaintext refresh tokens, authorization headers, or token-derived dictionary keys.

Do not silently broaden controller error handling. Do not treat fallback to a still-valid old access token as proof that refresh is healthy.
