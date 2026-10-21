---
name: testing-and-observability
description: Choose behavioral tests and operational evidence for architectural decisions and failure paths. Use in planning, implementation and independent review.
---

# Testing and observability

Link tests to the existing stable acceptance scenarios and reviewed revision. Prefer the smallest test boundary that can falsify the behavior: pure policy tests, repository/provider integration, contract tests or user-flow tests. Avoid tests that merely repeat implementation details or assert architectural vocabulary.

For structural changes prove behavior preservation and the claimed improvement. Exercise real serialization/query translation where mocks cannot establish it; use fault injection for cancellation, retries, duplicates and partial failure. Separate locally tested contracts from live-provider/deployment evidence.

Define useful correlation IDs, business operation identity, lifecycle metrics and actionable failure logs. Protect tokens, personal data and domain payloads. Do not replace durable audit facts with diagnostic logs.

Reviewer evaluates omitted scenarios and evidence limitations as well as test quantity. Verifier uses an independent counterexample and checks that results belong to the final revision. Report unavailable checks without presenting synthetic evidence as live validation.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/dotnet/skills/tree/main/plugins/dotnet-test
- https://github.com/addyosmani/agent-skills/tree/main/skills/browser-testing-with-devtools
