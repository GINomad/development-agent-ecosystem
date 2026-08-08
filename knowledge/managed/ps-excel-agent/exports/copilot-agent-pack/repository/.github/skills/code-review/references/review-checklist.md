# PS Excel review checklist

## Correctness and contracts

- Are TypeScript range indexes, JSON shapes, C# DTOs, validation, orchestration models, and custom-function metadata aligned?
- Does the change preserve default `Base`, tagged/untagged scenario routing, scalar/time-series parity, and scenario defaults?
- Could a partial project patch replace or delete existing scenarios/settings/variables?
- Are pending/running/completed calculation states, cancellation, cleanup, and polling terminal states consistent?

## Authentication and concurrency

- Are current OIDC tokens read at request time and rotated response tokens persisted?
- Can parallel requests reuse a rotating refresh token?
- Is successful refresh coalesced and reused, not merely serialized?
- Are AsyncLocal/ScopedContext values applied in the caller flow after async resolution?
- Can auth fail in middleware before controller refresh logic runs?

## Office.js and compatibility

- Are public functions, generated metadata, manifests, webpack assets, and VBA bridges synchronized?
- Does the code work in standalone Excel desktop, not only debugger/dev-server contexts?
- Does a non-cell shortcut path safely handle a missing invocation address?
- Does new syntax/library behavior respect the configured browser/runtime support?

## Configuration, security, and delivery

- Is the setting edited at the authoritative layer?
- Are runtime origin, HTTPS, tenant, and CORS behaviors correct?
- Could secrets enter source, logs, build args, layers, artifacts, or error messages?
- Do Docker ports, App Service settings, and pipeline parameters agree?
- Is the pipeline/run tied to the exact reviewed commit?

## Tests

- Does focused coverage prove the regression rather than only the happy path?
- Are concurrency tests deterministic and do they assert call counts/results?
- Are manual Excel checks clearly separated from automated verification?
- Are known warnings distinguished from new failures?
