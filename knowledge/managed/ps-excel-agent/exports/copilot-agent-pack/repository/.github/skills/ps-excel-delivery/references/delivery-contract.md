# Delivery and runtime configuration contract

## Configuration authority

The system has several layers:

- backend defaults in `appsettings.json` and environment-specific files;
- deployment environment variables/App Service settings using .NET hierarchical names;
- dynamic ASP.NET `/env.js` for browser-visible runtime settings;
- checked-in UI `env*.js` used by local/build flows;
- manifest source URLs and query parameters;
- Docker and Azure pipeline inputs.

Trace the effective value from source to browser/API consumer. Keep React and .NET configuration aligned. In hosted environments, generate `ExcelAgentApiUrl` from the browser/request origin where appropriate so reverse-proxy TLS does not produce mixed-content `http://` URLs.

Guard missing tenant/client ID before constructing Planning Space URLs. A CORS failure on a direct browser-to-Planning-Space request cannot be fixed by adding CORS headers to the Excel Agent server; use a same-origin proxy only as an explicit behavioral change.

## UI packaging and env.js

The backend project copies UI `dist` into `wwwroot` and currently deletes the copied `env.js`, while ASP.NET emits runtime configuration. Verify the actual middleware and build target before modifying it. Test the served `/env.js` response rather than inferring which file wins.

## Docker

- Keep the container listen address, `EXPOSE`, local port mapping, and App Service settings consistent.
- Use Docker BuildKit secrets/existing feed authentication for private NuGet packages.
- Never use a PAT in `ARG`/`ENV`, Git history, or build logs.
- Restore once and avoid persisting feed credentials into the final image or metadata.

Useful local smoke targets after an authorized/successful build:

- `/taskpane.html`
- `/env.js`
- `/functions.js`
- `/functions.json`
- referenced icons/assets

Check that `/env.js` contains the intended environment and an HTTPS/browser-safe API origin.

## Pipelines and deployments

Read the current YAML trigger configuration. Do not infer that a branch push queues every definition. Build queueing, image push, and deployment are external mutations; require authorization and exact parameters. Monitoring an already started run is read-only.

When a pipeline fails, identify the exact commit SHA and extract the failed task/log evidence. Do not conflate a run for another commit or a superseded image tag with the current change.
