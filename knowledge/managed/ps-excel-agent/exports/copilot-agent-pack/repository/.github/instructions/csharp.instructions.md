---
name: PS Excel C# rules
description: Backend and MSTest conventions for the PS Excel Agent.
applyTo: "**/*.cs"
---

- Match the namespace, dependency-injection, nullable, and async patterns in adjacent files.
- Use braces for every conditional branch.
- Keep one class per file and use explicit access modifiers. Prefer the narrowest practical visibility for non-public helpers.
- Keep helper methods at class scope. Do not create local functions merely to avoid adding a normal private method.
- Use `using` directives instead of fully qualified types in method and constructor signatures.
- Use `async`/`await`; do not introduce `.Result` or `.Wait()`.
- Use structured logging placeholders and never log bearer tokens, refresh tokens, authorization headers, secrets, or raw credential-bearing URLs.
- Do not add a controller action `try`/`catch` wrapper without explicit approval. Let the established middleware/error pipeline handle failures unless a specific exception contract requires local handling.
- For tests, use MSTest and Moq patterns already present. Name tests to communicate method, scenario, and expected behavior; cover concurrency and cancellation deterministically when those behaviors change.
- Re-read project files before changing target framework or package versions. Historical knowledge may mention older versions.
