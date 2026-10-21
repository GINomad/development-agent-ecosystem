# Global Engineering Code Standards

Scope: all repositories handled by the Development Agent Ecosystem. Technology-specific rules apply only where the language supports the construct. Repository rules may add stricter constraints. Business rules, domain behavior, API contracts, integration decisions, and product-specific behavior belong in repository-scoped knowledge instead of this file.

## Conditional blocks

Use braces for every `if`, `else if`, and `else` body, including a single statement. Apply this to C#, JavaScript, TypeScript, Java, and other brace-based languages. Do not convert unrelated legacy code solely to reformat it unless the task authorizes that scope.

Evidence: accepted ecosystem engineering standards. Private task, product and revision provenance is retained locally in knowledge/local/engineering-code-standards-provenance.md.

## Method organization by access and staticness

Within newly added or materially changed class members, order the access/static groups as follows:

1. `public static`
2. `public` instance
3. `protected static`
4. `protected` instance
5. `private static`
6. `private` instance

Keep changes local to task-owned members; do not create an unrelated whole-file reorder. When a language or repository uses another access level such as `internal` or package visibility and no accepted ordering rule exists, preserve its repository convention or request a decision instead of inventing a position.

Evidence: accepted ecosystem engineering standards. Private task, product and revision provenance is retained locally in knowledge/local/engineering-code-standards-provenance.md.

## Fields and properties before constructors and methods

Within newly added or materially changed C# types, place every field and property before every constructor and method. This includes members declared with `private`, `public`, `protected`, `internal`, or combined access modifiers. Do not leave a field or property after a constructor or method. Keep the change local to task-owned members; do not perform an unrelated whole-file reorder.

Evidence: accepted ecosystem engineering standards. Private task, product and revision provenance is retained locally in knowledge/local/engineering-code-standards-provenance.md.

## Functional JavaScript belongs in external assets

Do not place functional JavaScript implementation in Razor, HTML, or template files. Move complete behavior to an external `.js` or `.ts` asset and include it through the repository-standard asset or build mechanism. A declarative script reference or configuration that contains no functional implementation is permitted. Within standalone JavaScript, use the repository-compatible namespace/IIFE pattern or a closure.

Applicability: all repositories using Razor, HTML, or template-hosted JavaScript. Follow stricter repository-specific asset-loading rules where they exist.

Evidence: accepted ecosystem engineering standards. Private task, product and revision provenance is retained locally in knowledge/local/engineering-code-standards-provenance.md.

## TypeScript model declarations use one correctly named file

For newly added or materially changed TypeScript model declarations, place one declared type or type alias in a correctly named file under the repository's model/type boundary. Update imports and add or maintain a focused source-layout guard when the component already uses one. Keep unrelated legacy declarations out of scope unless the task explicitly authorizes their migration.

Applicability: TypeScript repositories that organize models or shared types by file. Follow stricter repository-specific folder conventions where they exist.

Evidence: accepted ecosystem engineering standards. Private task, product and revision provenance is retained locally in knowledge/local/engineering-code-standards-provenance.md.

## Promotion policy

Knowledge Keeper evaluates every confirmed review comment about code organization, formatting, naming, access modifiers, member ordering, braces, testing style, maintainability, and engineering principles for inclusion here or in a technology-scoped section. Promotion requires successful implementation when a change was requested and a later clean review. Bypassed, deferred, rejected, unresolved, speculative, or explicitly task-only guidance is not promoted.
