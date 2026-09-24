---
name: develop-javascript-typescript
description: Implement and review maintainable JavaScript and TypeScript using repository-compatible strictness, safe narrowing, modular boundaries, explicit asynchronous error handling, browser and Node compatibility, linting, and tests. Use for .js, .jsx, .ts, .tsx, Office.js, Node, and frontend build changes.
---

# Develop JavaScript and TypeScript

1. Inspect `package.json`, lockfile, runtime targets, module system, `tsconfig`, lint rules, formatter, and test runner before changing code.
2. Preserve the existing package manager and lockfile. Do not add or upgrade dependencies unless requirements justify the lifecycle and bundle cost.
3. Use ES modules and cohesive module boundaries where the configured runtime supports them. Keep mutable global state and import side effects out of reusable modules.
4. In TypeScript, preserve or strengthen project strictness. Prefer inference for local values, explicit public contracts, `unknown` plus narrowing at trust boundaries, and discriminated unions for meaningful state variants.
5. Avoid `any`, non-null assertions, broad casts, and optional chaining that merely hides a violated invariant. Document the evidence when an escape hatch is unavoidable.
6. Keep async control flow explicit. Await or return promises, handle rejection at an ownership boundary, preserve error causes where supported, and provide cancellation or stale-result protection for long-lived UI work.
7. Keep functions focused and side effects visible. Extract shared behavior only when it represents one concept and one change reason.
8. Preserve browser, Office host, Node, bundler, and transpilation compatibility evidenced by repository configuration.
9. Run type checking, linting, affected tests, and the actual build. Add focused tests for boundary validation, rejection paths, cancellation, and state transitions.
10. Reviewer: prioritize correctness, race conditions, unsafe types, unhandled promises, module coupling, compatibility, and missing tests over formatting preferences.

## Official references

- [TypeScript Handbook: everyday types and strictness](https://www.typescriptlang.org/docs/handbook/2/basic-types.html)
- [TypeScript compiler options](https://www.typescriptlang.org/docs/handbook/compiler-options.html)
- [MDN JavaScript modules](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules)
- [MDN Promise reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise)
