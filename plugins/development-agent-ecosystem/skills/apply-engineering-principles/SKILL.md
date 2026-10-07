---
name: apply-engineering-principles
description: Apply and review pragmatic DRY, KISS, SOLID, YAGNI, separation-of-concerns, testability, and maintainability principles. Use for implementation planning, code changes, refactoring, and code or agent-work review across any supported technology.
---

# Apply engineering principles

1. Preserve observed repository conventions unless a requirement or measured defect justifies changing them.
2. Prefer the smallest design that satisfies current requirements and tests. Do not add speculative extension points.
3. Apply KISS before patterns: reduce states, branches, indirection, and hidden control flow.
4. Apply DRY to duplicated knowledge or behavior, not merely similar syntax. Keep duplication when abstraction would couple unrelated change reasons.
5. Apply SOLID at real change boundaries:
   - keep one cohesive reason to change;
   - extend through a stable seam only when another implementation is evidenced;
   - preserve substitutability and caller contracts;
   - keep interfaces consumer-focused;
   - make policy depend on stable abstractions when infrastructure variation or test isolation requires it.
6. Keep side effects explicit and dependencies visible. Separate pure decision logic from I/O where practical.
7. Refactor only within ready scope. Preserve behavior with focused tests before structural change.
8. In review, cite the concrete maintenance, correctness, or testing cost. Do not report principle names as findings without an observable consequence.

## Mandatory repository engineering checks

Apply every check below to every new or resumed task, planning block, implementation block, review, and independent verification. These checks are mandatory even when the task text does not mention them. Record direct repository evidence for each applicable check. A check may be `not-applicable` only when the evidence explains why the changed scope cannot exercise it; an exception requires a recorded user decision, never a silent bypass.

1. **Dependency injection.** Inspect new or changed `IServiceProvider` resolution and service-locator patterns. Prefer constructor injection for consumers, with lifetime and ownership proven against the repository's composition root. Allow `IServiceProvider` only in an evidenced composition-root registration or factory delegate, or at a runtime boundary such as `NoInlining`, reflective/dynamic loading, plugin activation, or equivalent loading fallback; record the concrete boundary, lifetime/ownership, and why direct constructor injection cannot serve that use.
2. **Data access.** Keep every database operation in the repository's established data-access project and its existing repository/framework abstraction. Do not introduce database access in web, controller, business, or adapter layers. Establish the repository convention from direct code/project evidence before planning or implementation.
3. **Type layout.** Put every new class, interface, and enum in its own correctly named file and appropriate folder. Place static utility classes in `Helpers` or `Extensions` according to their role. Treat a deviation as requiring an explicit user decision with a concrete compatibility or generated-code reason.
4. **Stream and disposable ownership.** Trace `MemoryStream` and every changed `IDisposable` from creator through returned value and consumer. Prove ownership and disposal on success, failure, and cancellation. Do not dispose a returned stream before its consumer has finished; make the owner and disposal point explicit.

In requirements analysis, identify the repository evidence needed to apply these checks and hold only the affected scope when it is absent. In implementation, report the check and outcome with changed-file evidence. In review and verification, publish separate coverage evidence and a distinct falsification attempt for dependency injection, data access, type layout, and disposable ownership.

## Technology routing

- For C#, .NET, ASP.NET Core, or `.csproj`, also use `develop-dotnet`.
- For JavaScript, TypeScript, Node, or Office.js, also use `develop-javascript-typescript`.
- For React components or hooks, use both `develop-javascript-typescript` and `develop-react`.
- If the stack is uncertain, ask Knowledge Keeper for repository evidence instead of guessing.
