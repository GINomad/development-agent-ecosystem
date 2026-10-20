---
name: analyze-requirements
description: Analyze development requirements and assess whether an idea merits investment using code, tests and evidence. Use for idea assessment, specification and implementation-ready planning.
---

# Analyze Requirements

All new tasks use spec-practices-1.0.0 by default, without pilot enrollment. In the managed runtime, read task.json and copy its practiceVersion into requirements-analysis.json. For legacy resumes without a task version, preserve the existing analysis version or use legacy if absent; never upgrade resumed tasks implicitly. For new tasks use [specification](assets/specification.md), [plan](assets/plan.md) and [task slices](assets/tasks.md) as drafting guides, scaled to scope. Small fixes may keep the relevant sections inline instead of creating separate documents. Keep existing JSON contracts authoritative; Markdown is a presentation, not a second completion database. For explicit idea/investment assessment, read [idea assessment](references/idea-assessment.md) instead. In standalone chat, apply these guides by default to new tasks and return results inline without claiming runtime persistence. Do not relabel historical tasks to fill a comparison cohort.

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
