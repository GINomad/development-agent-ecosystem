---
name: refresh-ps-excel-knowledge
description: Persist a confirmed engineering decision in the canonical PS Excel knowledge base and reconcile Copilot skills.
agent: PS Excel Engineer
argument-hint: Describe the confirmed decision and provide evidence or changed files.
---

Update the canonical knowledge root `C:\Repos\AI Knowledge\ps_excel_agent` only after validating the new fact against current source, tests, logs, or an explicit user decision.

Use the routing rules in `ps-excel-knowledge-base`. Update the existing document that owns the topic. Include the decision, evidence, affected files, verification, date, limitations, and any superseded approach. Do not store secrets, tokens, raw credential-bearing logs, temporary IDs, or unverified conclusions.

Then find the single canonical instruction or skill reference that owns the agent behavior. Replace superseded guidance instead of accumulating contradictions. Preserve historical context only when it prevents repeating a known failed approach. Keep `SKILL.md` concise and move detailed domain knowledge into a directly linked reference.

Validate frontmatter, links, and consistency across affected instructions, agents, prompts, and skills. Report exactly which canonical knowledge files and Copilot customization files changed and what evidence justified each update.
