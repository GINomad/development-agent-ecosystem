# Planning guide

Capture the observed repository stack, existing boundaries, relevant interfaces/contracts, alternatives and the simplest supported approach. Cite the source revision and selected knowledge revision. Reuse the configured project principles and engineering guidance; do not generate a competing constitution or change task branches.

For authorized implementation, map each plan step to ready requirementIds and observable validation. Explain dependencies, risks and heldScope. Emit the normal implementation-plan.json fields: taskId, branch, baseBranch, requirementsRevision, knowledgeRevision and steps (id, requirementIds, files, change, validation).

Populate requirements-analysis.json.plan and humanReadable.implementationPlan consistently. Research-only has empty implementation plans; its workflow ends at the research outcome. Do not create a fake nonempty implementation-plan.json for research just to satisfy a delivery schema.

Dependency injection, data-access boundaries, type layout and disposable ownership use the existing engineering skill. Record applicability with direct evidence, rather than copying generic architecture into every task.
