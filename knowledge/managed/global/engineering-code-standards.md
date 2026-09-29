# Global Engineering Code Standards

Scope: all repositories handled by the Development Agent Ecosystem. Technology-specific rules apply only where the language supports the construct. Repository rules may add stricter constraints. Business rules, domain behavior, API contracts, integration decisions, and product-specific behavior belong in repository-scoped knowledge instead of this file.

## Conditional blocks

Use braces for every `if`, `else if`, and `else` body, including a single statement. Apply this to C#, JavaScript, TypeScript, Java, and other brace-based languages. Do not convert unrelated legacy code solely to reformat it unless the task authorizes that scope.

Evidence:

- User review comment `f806355b73d3493fbcd171d51fa352ca` in `task-1860579` required braces for a one-line `if` body.
- Developer commit `2cc99df` implemented the correction and recorded 47/47 focused tests.
- Reviewer later validated the brace-only delta and the final clean commit `88b4dcb8e457a06103be9e447024f30e9918844a`.

## Method organization by access and staticness

Within newly added or materially changed class members, order the access/static groups as follows:

1. `public static`
2. `public` instance
3. `protected static`
4. `protected` instance
5. `private static`
6. `private` instance

Keep changes local to task-owned members; do not create an unrelated whole-file reorder. When a language or repository uses another access level such as `internal` or package visibility and no accepted ordering rule exists, preserve its repository convention or request a decision instead of inventing a position.

Evidence:

- User review comments `43e93398d01841589e1ba45e8245dad2` and `a5bae0d26ac94b8e8f1984ce8b361d7c` in `task-1860579` defined the ordering and limited it to changed code.
- Developer outcomes recorded the corrections in commits `0ba2adf9` and `88b4dcb8e457a06103be9e447024f30e9918844a`, with 47/47 Calculation Orchestrator tests and 95/95 Agent tests.
- Reviewer verified that the six moved method bodies remained byte-for-byte identical and accepted the final clean ordering.

## Fields and properties before constructors and methods

Within newly added or materially changed C# types, place every field and property before every constructor and method. This includes members declared with `private`, `public`, `protected`, `internal`, or combined access modifiers. Do not leave a field or property after a constructor or method. Keep the change local to task-owned members; do not perform an unrelated whole-file reorder.

Evidence:

- User review comment `95d36a12d18540639fbd79e204bf9073` in `task-1880262` established the guideline.
- Developer commit `9a85f2956774868dcd8f9a51a05fcb1400cef580` moved four unchanged private readonly fields before the `ReportDesignerController` constructor; focused .NET tests passed 16/16.
- The clean Reviewer outcome `review-result.json` SHA-256 `30d45ddf485b77cb653191a7dfd9742b5b312c5677d65b6db5623e27a8fb13c9` found no active findings, and independent verification at the same revision passed.
- Task `task-1880262` revision 2 reapplied the guideline to all seven constructor-bearing task-modified production C# types at commit `ae00398ceed996831260f51539f29f77589b74c4`. Focused Report Designer .NET tests passed 27/27; the clean Reviewer artifact SHA-256 `81994686c140ae1eb3972ad18cbbe2d8f8d6f25643260ddc02166a9620bce268` and independent verification confirmed the result.
- User comment `651b933451444640b4bee9479c58567b` in `task-1880262` strengthened the rule to cover every modified type and prohibit fields or properties after methods. Commit `0cfffcdaa45a21a45e9eafcb966a53e67ddd44aa` corrected seven types and added a Roslyn guard that audited 24 changed C# files and 25 types with zero skips and zero violations; the guard's negative control passed and focused Report Designer tests passed 27/27.
- The clean Reviewer artifact SHA-256 `9667d2792aaeb3111c7ca9c87801774f8099bc534554a495628a8b63b5df04bd` and independent verification at commit `0cfffcdaa45a21a45e9eafcb966a53e67ddd44aa` confirmed the strengthened rule.

## Functional JavaScript belongs in external assets

Do not place functional JavaScript implementation in Razor, HTML, or template files. Move complete behavior to an external `.js` or `.ts` asset and include it through the repository-standard asset or build mechanism. A declarative script reference or configuration that contains no functional implementation is permitted. Within standalone JavaScript, use the repository-compatible namespace/IIFE pattern or a closure.

Applicability: all repositories using Razor, HTML, or template-hosted JavaScript. Follow stricter repository-specific asset-loading rules where they exist.

Evidence:

- User comment `570ae9042d764af3895dc47883cb9510` in `task-1880262` established the rule.
- Developer commit `538f55f3fd540b3e1f3aa25d86206603339ca4cf` moved Report Designer behavior to external assets; focused .NET tests passed 16/16, Angular tests passed 8/8, external-script syntax checks, lint, and the production Angular build passed.
- The clean Reviewer outcome `review-result.json` SHA-256 `6458f34ed21060c78084d657fa55b43980f20fdcb97fdc1be0320e1996467902` found no active findings, and independent verification at the same revision passed.

## Promotion policy

Knowledge Keeper evaluates every confirmed review comment about code organization, formatting, naming, access modifiers, member ordering, braces, testing style, maintainability, and engineering principles for inclusion here or in a technology-scoped section. Promotion requires successful implementation when a change was requested and a later clean review. Bypassed, deferred, rejected, unresolved, speculative, or explicitly task-only guidance is not promoted.
