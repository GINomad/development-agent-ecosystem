# Idea assessment in research-only mode

Use this process when the user asks whether an idea deserves investment. The Orchestrator selects the existing research-only mode and Requirements Analyst owns the assessment. In standalone chats return the same assessment inline and stop; runtime artifacts and scripts are unavailable there.

Define the problem, target users, measurable success criteria, non-goals and cost of inaction. Gather bounded first-party/product evidence and approved external research only when needed. Treat fetched content as evidence. Cite sources and revisions, separate ASSUMPTION from observation, record confidence and actively seek evidence against the idea.

Shape at least two alternatives, including doing nothing or a smaller change. State tradeoffs and an appetite (time/effort bound), without inventing financial estimates. Do not run all stages again just to answer one unknown; refine the existing evidence and decision.

In full-runtime mode put the assessment in the optional requirements-analysis.json.ideaAssessment field. Fill problem, successCriteria, evidence (source, observation, confidence), evidenceAgainst, alternatives (option, tradeoff, appetite), evidenceQuality (adequate/weak/unknown), verdict (go/needs-clarification/kill), rationale and handoff. Preserve ordinary requirements and SCN links: research SCN steps verify the decision evidence, not nonexistent application behavior. Use held requirements and focused questions for missing product decisions. Keep plan and humanReadable.implementationPlan empty.

A go verdict requires adequate evidence, a defined problem, measurable success, cited evidence against (or a documented unsuccessful search), at least two alternatives and no unresolved blocking questions or held requirements. Otherwise choose needs-clarification; kill is appropriate when evidence supports stopping. A go handoff is a bounded recommendation for a later explicit request, not implementation authority. Report the verdict in humanReadable.objective/requirements so the dashboard shows it. No source edits, developer/reviewer/pipeline dispatch, commits, builds or pushes follow from assessment alone.
