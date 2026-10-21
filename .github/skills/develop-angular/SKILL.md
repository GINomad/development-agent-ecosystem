---
name: develop-angular
description: Plan, implement and review Angular components, routing, dependency injection, RxJS and tests using the repository's Angular version. Use for Angular frontend changes and architecture.
---

# Develop Angular

Read package manifests and nearby first-party components to establish Angular/TypeScript/RxJS versions, module versus standalone conventions, forms, test runner and state ownership. Use develop-javascript-typescript as the language baseline. Do not migrate an older application to current Angular APIs as an incidental change.

Keep components focused on presentation and user interaction; put shared state and I/O in evidenced services/stores. Select local component state, signals, RxJS or the existing store according to ownership, lifetime and asynchronous semantics. Do not introduce a global store for transient state or duplicate server data without an invalidation rule.

Check DI provider scope, singleton versus route/component lifetime, guards and resolvers, lazy routes, change detection, immutable inputs and stable list identity. Use signals/control-flow/standalone APIs only when supported by the installed version and repository conventions.

For RxJS, choose switchMap/concatMap/exhaustMap/mergeMap by cancellation, ordering and concurrency requirements; catch errors at the intended boundary and prove teardown on navigation/destruction. Prefer the async pipe or version-supported lifecycle teardown; avoid nested subscriptions and hidden resubscription effects.

Use accessible controls, keyboard/focus behavior, explicit loading/error/empty states and safe template bindings. Trace authentication and tenant state across navigation; route guards do not replace server authorization. Validate iframe origins, message shape and listener cleanup where relevant.

Test user behavior and failure/cancellation paths with the existing runner. Run the affected Angular tests, TypeScript/lint and production build when relevant. Review for needless services, wrappers, RxJS complexity and shared mutable state as well as missing boundaries.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/angular/skills/tree/main/angular-developer
- https://angular.dev/guide
