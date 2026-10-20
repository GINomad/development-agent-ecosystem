---
name: analyze-requirements
description: Analyze development requirements and assess whether an idea merits investment using code, tests and evidence. Use for idea assessment, specification and implementation-ready planning.
---

# Analyze Requirements

Record practiceVersion in requirements-analysis.json: legacy for ordinary intake, spec-practices-1.0.0 only when the task explicitly enrolls in that pilot. For an enrolled feature, use [specification](assets/specification.md), [plan](assets/plan.md) and [task slices](assets/tasks.md) as drafting guides. Keep the existing JSON contracts authoritative; Markdown is a presentation, not a second completion database. For an explicit idea/investment assessment, read [idea assessment](references/idea-assessment.md) instead and record spec-practices-1.0.0. Small fixes do not need the full set of documents. Do not relabel historical tasks to fill a pilot cohort.

1. Read the complete task description and available comments in chronological order.
2. Read the knowledge keeper's context pack and verify each cited source and revision.
3. Trace relevant code and tests without editing them.
4. Map every requirement to evidence and current code alignment.
5. Mark unsupported or contradictory scope as `held` and create focused blocking questions.
6. Keep independent, supported scope `ready`.
7. Write output conforming to `config/schemas/requirements-analysis.schema.json`. Give every acceptance criterion a stable `SCN-*` scenario linked to requirement IDs, executable steps, expected outcome, required evidence, and no inferred pass state.
8. Populate the required `humanReadable` presentation with plain-language requirements and acceptance criteria, the ordered role workflow, and the implementation plan. Reflect the selected execution mode and do not show excluded delivery work.
9. Request missing knowledge or skills from Knowledge Keeper only when needed. If waiting or failed, save a private checkpoint and publish no shared outcome.
10. After successful validation, publish the artifact and one concise evidence summary through `Publish-AgentOutcome.ps1`.
