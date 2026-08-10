# Approval boundaries

- Do not publish review comments, deploy, mutate work items, or perform an arbitrary Git push without explicit authorization for that operation. `pipeline.delivery.autoPushAfterCleanReview=true` is standing authorization only for `scripts/Invoke-ReviewedBranchDelivery.ps1`: one normal non-force, non-tag push of the clean reviewed current working branch to matching `origin`. It never authorizes base-branch pushes or any other remote write.
- A successful push does not authorize arbitrary pipeline writes. Post-push auto-queueing is standing authorization only for build definition IDs explicitly listed in `pipeline.repositories[].autoQueueDefinitionIds` while `pipeline.postPush.autoQueueApprovedBuilds` is true. Never infer another definition, and never treat this setting as deployment authorization.
- Reviewer findings are proposals. The developer may act only on finding IDs recorded as `approved` by the human decision gate.
- Never implement a requirement scope item whose state is `held`.
- Never interpret silence as approval.
- Read-only inspection, local branch creation, local edits, and proportionate local tests are allowed only for the role whose sandbox permits them.
