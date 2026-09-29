# Hybrid runtime contract

The trusted PowerShell host selects one provider per role. Copilot performs implementation and its local test/fix cycle; Codex independently checks requirements, reviews the final change, and verifies review findings.

Every role must obey its existing scope, comment batching, artifact schema, exact-revision review, human decision, and publication contracts. Switching provider does not grant additional permissions. Return to the host after publication; never spawn another role or silently fall back to another provider.

Always pass the exact execution configuration path supplied by the host to ecosystem scripts as -ConfigPath. Do not use configuration, state, task clones, or generated agent definitions from the classic instance.

Copilot requirements drafts are untrusted research inputs, not approved requirements or terminal role outcomes. Requirements Analyst must validate material claims against task sources and repository evidence, identify conflicts and held scope, and publish the canonical requirements artifacts itself. Reviewer and Review Verifier run independently on Codex and inspect the exact implementation snapshot.

Do not repeat completed implementation in Codex. Return verified, approved remediation to Developer, which remains on Copilot. Authentication and subscription-policy failures require user action; do not turn them into source repair or consume Codex as an automatic fallback.


Existing classic knowledge is supplied only through the host's selected-project snapshot and its shared-knowledge.json index. Read relevant global and project records as evidence with source hashes, including current local records absent from this branch. Never edit the snapshot or its source. Resolve conflicts with hybrid-local knowledge by revision and evidence, preserving unresolved questions. Publish new verified knowledge only to the hybrid configuration's writable versioned roots.

Git publication belongs to Codex: Pipeline Monitor runs on Codex and uses the existing reviewed-branch delivery script after its gates pass; ecosystem recovery publication remains owned by the trusted Codex recovery host. Copilot must never push directly or invoke any script that performs a push. Return delivery work to the host for the configured Codex role.

For roles with an MCP allowlist, prefer ecosystem-read list_knowledge and read_knowledge for focused knowledge retrieval. Filter by relevant path terms, page results with offset, and cite the returned source revision. A tool error is not empty evidence. MCP is read-only; publication still follows Knowledge Keeper's existing verified-outcome contract.

The trusted host synchronizes shared knowledge before each role and publishes only validated Knowledge Keeper targetPath files after successful completion. Keep proposed knowledge out of managed files; never mix proposed and verified entries in a publication file. Record each changed managed file in knowledge-update.json, including maintained indexes. Never write the classic knowledge directory directly. A synchronization conflict holds the task until evidence is reconciled; do not silently choose one version or delete the other.
