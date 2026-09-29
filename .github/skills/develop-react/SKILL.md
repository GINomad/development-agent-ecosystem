---
name: develop-react
description: Implement and review modern React components and hooks using purity, immutable state, minimal state ownership, correct Hooks usage, deliberate Effects, accessible UI, and repository-native testing. Use for React .jsx or .tsx components, hooks, state flow, rendering, and frontend behavior.
---

# Develop React code

1. Inspect the installed React version, rendering model, router or data framework, state library, ESLint React Hooks rules, component conventions, and test utilities.
2. Keep components and Hooks pure: same inputs produce the same render output, render does not mutate external values, and props/state remain immutable snapshots.
3. Call Hooks only where React permits and keep dependency lists complete. Do not suppress `rules-of-hooks` or `exhaustive-deps` to conceal an unstable design.
4. Store only minimal source-of-truth state. Compute derivable values during render; avoid mirrored props and duplicated state.
5. Use Effects only to synchronize with an external system. Put user-triggered behavior in event handlers and derived calculations in render or justified memoization.
6. Make Effects independently startable and stoppable. Return cleanup, prevent stale async results, and ensure development remounts do not duplicate durable side effects.
7. Keep state at the nearest common owner that needs it. Prefer explicit composition and data flow before context or a new global store.
8. Preserve semantic HTML, keyboard behavior, focus, accessible names, loading, empty, error, and disabled states.
9. Optimize only with measured evidence. Do not add memoization merely to satisfy a principle or silence a render concern.
10. Test observable behavior and important accessibility paths. Run React Hooks linting, type checking, affected tests, and the production build.
11. Reviewer: treat purity, Hook order, stale closures, duplicated state, Effect cleanup, accessibility, and user-visible race conditions as correctness concerns.

## Official references

- [Rules of React](https://react.dev/reference/rules)
- [Thinking in React](https://react.dev/learn/thinking-in-react)
- [You Might Not Need an Effect](https://react.dev/learn/you-might-not-need-an-effect)
- [`eslint-plugin-react-hooks`](https://react.dev/reference/eslint-plugin-react-hooks)
