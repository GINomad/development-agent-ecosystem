---
name: ps-excel-delivery
description: Diagnose or change ps-excel-agent runtime configuration, dynamic env.js, manifests, Docker builds, private NuGet authentication, container ports, Azure pipelines, App Service settings, CORS/origin behavior, packaging, deployment, or environment-specific URLs.
---

# PS Excel delivery and runtime configuration

1. Read [references/delivery-contract.md](references/delivery-contract.md).
2. Identify the authoritative source and runtime consumer for every setting being changed.
3. Inspect current `Program.cs`, `.csproj`, `appsettings*`, `env*.js`, manifest, Dockerfile, pipeline, and deployment repository when relevant.
4. Keep secrets out of source, layers, build arguments, logs, and prompts.
5. Distinguish local verification, pipeline monitoring, build queueing, image push, and deployment. External writes require explicit authorization.
6. Verify the effective runtime output, not only the source file.

Do not assume historical branch names, run IDs, ports, URLs, or pipeline triggers are still current.
