---
name: PS Excel Office add-in rules
description: TypeScript, React, Office.js, custom-function, authentication, and logging conventions.
applyTo: "planningspace.integration.excel.ui/**/*.{ts,tsx,js,json,html}"
---

- Use braces for every `if`, `else if`, and `else` branch.
- Preserve compatibility with the Excel desktop runtime and the repository browserslist, including IE 11 where existing code still targets it. Avoid unsupported syntax or promise patterns unless the build/transpilation path is confirmed.
- Reuse `callApi` for authenticated Excel Agent requests so tenant/client headers, token rotation, and error conversion remain consistent.
- Read the current OIDC `User` immediately before constructing long-running request headers; do not assume an object captured at calculation start still contains rotated tokens.
- Use `updateUserTokens` for rotated response token persistence.
- Route workbook logging through the shared logging helpers. Shortcut or non-cell flows may have no invocation address; do not force an Excel log-sheet write for an empty/uninitialized address.
- Keep custom-function implementation, JSDoc metadata generation, `functions.json`, manifest declarations, and webpack assets consistent when a public function contract changes.
- Treat Office keyboard shortcuts, shared runtime initialization, dialog auth, and workbook/VBA bridges as runtime-sensitive. Read the matching skill and preserve confirmed fallback behavior.
- Run the focused UI build after changes; validate the manifest when metadata, URLs, permissions, or extension points change.
