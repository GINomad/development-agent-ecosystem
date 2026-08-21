---
name: analyze-requirements
description: Analyze assigned development tasks and comments against code, tests, and selected knowledge; identify evidence-backed conflicts, questions, ready scope, held scope, and implementation plans. Use before implementing a task or when requirements change or remain ambiguous.
---

# Analyze Requirements

1. Read the complete task description and available comments in chronological order.
2. Read the knowledge keeper's context pack and verify each cited source and revision.
3. Trace relevant code and tests without editing them.
4. Map every requirement to evidence and current code alignment.
5. Mark unsupported or contradictory scope as `held` and create focused blocking questions.
6. Keep independent, supported scope `ready`.
7. Write output conforming to `config/schemas/requirements-analysis.schema.json`.
8. Populate the required `humanReadable` presentation with plain-language requirements and acceptance criteria, the ordered role workflow, and the implementation plan. Reflect the selected execution mode and do not show excluded delivery work.
9. Request missing knowledge or skills from Knowledge Keeper only when needed. If waiting or failed, save a private checkpoint and publish no shared outcome.
10. After successful validation, publish the artifact and one concise evidence summary through `Publish-AgentOutcome.ps1`.
