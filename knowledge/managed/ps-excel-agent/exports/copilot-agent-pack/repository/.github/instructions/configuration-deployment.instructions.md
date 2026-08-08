---
name: PS Excel configuration and delivery rules
description: Runtime configuration, Docker, manifest, and Azure pipeline constraints.
applyTo: "{Dockerfile,azure-pipeline*.yml,planningspace.integration.excel.agent/appsettings*.json,planningspace.integration.excel.ui/env*.js,planningspace.integration.excel.ui/manifest.xml,Manifests/*.xml}"
---

- Identify the authoritative source for each setting before editing it: checked-in defaults, environment variables/App Service settings, dynamic `/env.js`, manifest query parameters, or pipeline inputs.
- Keep UI and backend effective configuration aligned. Do not bake environment-specific secrets or credentials into UI assets or container layers.
- Preserve the dynamic runtime `/env.js` behavior and verify which middleware/asset wins instead of assuming static-file precedence.
- Use BuildKit secrets or the existing authenticated feed mechanism for private NuGet access. Never restore the historical build-arg/PAT pattern.
- Keep container listen ports consistent with Docker metadata and deployment settings.
- Treat pipeline queueing, image pushes, and deployments as external writes requiring explicit authorization. Monitoring is read-only unless queueing was explicitly approved.
- For environment and URL changes, verify HTTPS/origin behavior behind reverse proxies and guard against missing tenant values.
- Run manifest validation when manifest metadata, URLs, permissions, requirement sets, custom functions, or runtime declarations change.
