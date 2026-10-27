# LSS knowledge publication: direct Active non-FPI policy capture

Status: published to the selected local project knowledge root only.

Knowledge entry: `.runtime/local-projects/strive-lss/knowledge/lss-active-policy-20261027.md`

Source revision: `5df612639fe2f01c6c61f2f65618d99555727567` on `features/lss-loan-page-main-insurance` (base `c9e96b3de9465a6ae1a0aed05b9f615d879a5661`).

The entry records the verified standalone Active non-FPI creation path, its persisted state, guarded edit boundary, explicit status/idempotency protections, and the fact that it does not implement FPI workflow or general status lifecycle. It also records separate holds for Agent-field schema rollout, DMS deployment/mapping, Legal FPI, and unavailable runtime dependencies.

Review evidence: `work/lss-active-policy-20261027-review-r2.json`, SHA-256 `1624D2EA89EB710949597A3E9A7B092071C7FB649A3D2DF7D645FD824B6A810C`.

Independent verification evidence: `work/lss-active-policy-20261027-verification-r2.json`, SHA-256 `96B3549D43A4C99473C15383B3544C595C08002492618ACE187B199EA57CAF3D`.

Boundary validation: `Test-PublicationBoundary.ps1` passed with `TrackedFiles=0`, `PrivateFiles=0`, `Scope=index` for the selected knowledge root. No global standards, product source, remote repository, work item, deployment, or DMS state was changed.

Residual risk: runtime .NET and Angular execution was unavailable because `project.assets.json` and `node_modules` were absent; the entry makes no runtime or production-readiness claim.
