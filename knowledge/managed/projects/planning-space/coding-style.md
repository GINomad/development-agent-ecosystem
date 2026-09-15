# PS Excel Agent Coding Style

Universal engineering rules are maintained in ../global/engineering-code-standards.md and apply to every configured repository. This file contains only ps-excel-agent-specific additions or provenance retained from the imported seed knowledge.

Source repository: `C:\Repos\ps-excel-agent`
Knowledge base path: `C:\Repos\AI Knowledge\ps_excel_agent`
Created: 2026-06-26

## Conditional Blocks

All `if`, `else if`, and `else` statements should use braces, even when the body contains only one line.

Preferred:

```ts
if (body) {
  headers["Content-Type"] = "application/json";
} else {
  headers["Accept"] = "application/json";
}
```

Avoid:

```ts
if (body) headers["Content-Type"] = "application/json";
else headers["Accept"] = "application/json";
```

Apply this consistently in future edits to TypeScript, JavaScript, and C# files in this project.

## Change Review and Diff Presentation

After making code or knowledge-base changes, use the native per-file `Edited <file>` change cards with the `Review` action whenever the editing tool provides them.

- Do not automatically open all diffs in the user's IDE.
- Let the user choose which change card they want to review.
- Keep task changes separated by file so each changed file has its own reviewable card when possible.
- If native change cards cannot be produced for pre-existing or externally made changes, present the changed-file list in chat as a fallback and open only the diffs selected by the user.

## Maintaining This File

When the user gives a new coding style preference for this project, update this document so future work can apply it consistently.
## Controller Error Handling

Do not wrap controller action code in new `try`/`catch` blocks without asking for approval first. Preserve existing error handling unless the user explicitly approves changing it.
## Type and Member Organization

Place each class in its own file. When a type does not need to be public, make it `internal`.

Apply explicit access modifiers to methods based on actual usage. Prefer the narrowest practical access level.

Do not declare methods inside other methods. Move helper methods to the class definition and choose an appropriate access modifier. Static extension classes are acceptable when they make the call site clearer.

Use `using` directives instead of fully qualified type names in method parameters or constructor parameters.


