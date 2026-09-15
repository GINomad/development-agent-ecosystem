# Pull Request Review Checklist

Apply this checklist with engineering judgment. Report only evidence-backed defects, risks, regressions, or meaningful maintainability problems. Do not manufacture findings merely to cover every question.

## General

- Does the code work and perform its intended function? Is the logic correct?
- Is the code easy to understand?
- Does it conform to the agreed coding conventions, including brace placement, names, line length, indentation, formatting, comments, and file location?
- Is there redundant or duplicate code?
- Is the code as modular as reasonably possible?
- Can global variables be removed or replaced with narrower state?
- Is there commented-out code that should be removed?
- Do loops have correct termination conditions and, where applicable, a bounded length?
- Can custom code be replaced with an established library or existing project function?
- Can logging, temporary diagnostics, or debugging code be removed?

## Security

- Are all inputs validated for type, length, format, and range, and encoded where required?
- Are failures returned by third-party utilities and services handled correctly?
- Are output values validated and encoded for their destination?
- Are invalid parameter values handled explicitly and safely?
- Do authentication, authorization, tenant boundaries, secrets, and ownership checks remain correct?

## Testing

- Is the code testable, with dependencies visible and replaceable, objects constructible, and relevant methods reachable by the test framework?
- Do tests exist for the changed behavior, and are they comprehensive enough for the agreed coverage expectations?
- Do unit tests verify intended behavior rather than implementation details?
- Are array and collection boundaries handled safely?
- Can custom test code be replaced with an existing project test API, fixture, helper, or framework capability?
- Are failure paths, edge cases, concurrency, cancellation, and regression scenarios covered where relevant?

## Documentation

- Do comments describe intent and constraints rather than restate obvious code?
- Are functions commented where required by the project conventions, especially public or non-obvious behavior?
- Is unusual behavior or edge-case handling documented?
- Are the purpose and constraints of third-party libraries documented where needed?
- Are data structures, formats, and units of measurement explained?
- Is there incomplete code? Should it be removed or explicitly marked with an actionable `TODO`?

## Feedback And Ownership

- Give the reviewer a concise high-signal summary while making the underlying findings comprehensive enough for the author to act on.
- Include severity, file and line, impact, reasoning, and the expected correction direction for each finding.
- Distinguish new findings, unresolved previous findings, and fixed findings when prior review state is available.
- Do not modify the PR branch or fix findings on the author's behalf. The PR author owns the corrections and action items.
