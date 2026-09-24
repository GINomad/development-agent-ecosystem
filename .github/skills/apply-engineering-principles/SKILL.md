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

## Technology routing

- For C#, .NET, ASP.NET Core, or `.csproj`, also use `develop-dotnet`.
- For JavaScript, TypeScript, Node, or Office.js, also use `develop-javascript-typescript`.
- For React components or hooks, use both `develop-javascript-typescript` and `develop-react`.
- If the stack is uncertain, ask Knowledge Keeper for repository evidence instead of guessing.
