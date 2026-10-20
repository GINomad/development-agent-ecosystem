# Specification drafting guide

Map this presentation into requirements-analysis.json and humanReadable; do not publish a parallel source of truth.

Describe the user problem, expected value, measurable outcome, non-goals and constraints. Label assumptions and cite evidence with revisions.

For each prioritized user journey, record why it matters and how it delivers value independently. Give each requirement a stable REQ-* ID and preserve existing IDs on revision. List edge cases, error behavior and explicit exclusions. Mark unsupported decisions held; do not cap the number of real unknowns or guess a business/security decision to complete the template.

Each acceptance criterion gets one stable SCN-* with requirementIds, preconditions, executable steps, expectedOutcome and evidenceRequired. Each requirement links back through acceptanceScenarioIds. Keep both directions consistent. Include observable success criteria; separate post-launch business KPIs from build-verifiable acceptance criteria.

Use requirements[].status (ready/held/rejected/already-satisfied), evidence and codeAlignment. Mirror understandable titles, descriptions and acceptance criteria into humanReadable.requirements. A draft is not a verified result.
