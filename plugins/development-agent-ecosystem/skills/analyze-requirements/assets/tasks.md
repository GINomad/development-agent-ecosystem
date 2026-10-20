# Independently verifiable task slices

Organize the normal plan by prioritized user journey. A slice identifies step ID, ready requirementIds, stable SCN-* acceptance IDs, exact files, prerequisites and executable validation. Shared foundations precede dependent slices; flag parallel opportunities only where files and dependencies permit them. The ecosystem scheduler owns execution and isolation.

Include repository-appropriate tests even when the ticket does not request them. Test-first is useful for reproducible defects; avoid imposing it on documentation-only work. Verification evidence belongs in implementation-result.json.scenarioResults and review-result.json.requirementTraceability, bound to the final commit. Checkboxes and summaries do not prove completion.

Inspect missing, partial, contradictory and unrequested behavior during normal review. Map gaps to stable finding IDs and existing human decisions. New tasks or corrective work remain subject to ready/held scope and the existing independent review gate; do not append work that automatically authorizes itself.
