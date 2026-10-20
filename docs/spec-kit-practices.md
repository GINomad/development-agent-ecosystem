# Measured specification practices

This adoption uses the existing Requirements Analyst skill, routing, task JSON contracts and native plugin distribution. It introduces no Spec Kit runtime dependency. The drafting guides are original ecosystem adaptations of Spec Kit's specification/plan/task-slicing concepts and idea assessment, referenced at upstream **v1.2.2**: https://github.com/github/spec-kit/tree/v1.2.2. Upstream is MIT licensed: https://github.com/github/spec-kit/blob/v1.2.2/LICENSE. No upstream code or template text is vendored.

## Measures and interpretation

`New-HarnessEvaluationReport.ps1` is a deterministic, read-only collector of existing task artifacts. Its v2 output includes source SHA-256 fingerprints, nulls for unavailable observations and an observed-task denominator for each aggregate. Consumers of v1 must accept v2 and nullable counts. Total metrics are null if any selected task lacks that observation; inspect per-task metrics or select a complete cohort rather than treating partial totals as complete.

| Metric | Formula and source | Collection / missing data | Pilot criterion |
|---|---|---|---|
| Requirement linkage | Bidirectionally linked requirements / all requirements from requirements-analysis.json | Every snapshot; absent analysis is null | 100% |
| Verified acceptance | Ready/already-satisfied SCNs with passed implementation evidence and verified review evidence at the same final commit / ready SCNs | Review verifier must pass and bind exact review SHA and revision; held SCNs are excluded; absent analysis is null | 100% treatment |
| False completion | Completed delivery task missing summary/ready scenarios or not fully verified | Research is not delivery; missing execution mode is unknown | Zero treatment |
| Human interventions | User ledger comments, question resolutions, review decisions, reopen and close requests | Sum observed events; missing/corrupt ledger is null | Per-task count; candidate improvement >=10% |
| Clarifications | question-opened ledger events | Existing structured human-input contract; missing ledger is null | Diagnostic; fewer is not automatically better |
| Review rework | max(0, Reviewer agent-result events - 1) | Publication cycles, not inferred code changes; missing ledger is null | Diagnostic per task |
| Failures / recovery | agent-failure events / successful health_check agent-result events | Recovery outcome count, not a success ratio; missing ledger is null | No higher failures per task |
| Elapsed duration | task-summary.completedAtUtc - task.createdAtUtc | Completed tasks only; invalid/missing times are null; includes user wait | Candidate improvement >=10% |
| Stage execution | Sum role-metrics.durationMs grouped by agentId, plus attempt count | Only role-attempt-completed; missing stream is null, negative duration unavailable | Diagnostic; independent from elapsed time |
| Reported tokens | Sum fully reported totalTokens, including fallback models | Partial/unavailable usage is null, with unavailableUsageRecords; no price estimate | Candidate improvement >=10% per task |
| Artifact/context overhead | Bytes of current requirements, plan, review and optional assessment; bytes of current context-pack | Current snapshot, not cumulative read tokens; missing artifacts remain unknown | <=20% per-task increase |

These are evidence-contract measurements, not proof of runtime correctness. Normal Reviewer and Review Verifier checks remain authoritative. A verified claim must match the final implementation commit and current review artifact. Dollar cost remains unavailable until actual billing or a pinned price model with all necessary token categories exists; do not estimate cost by multiplying a generic token price.

Snapshot after terminal completion and before any change to prompts/process for the baseline arm. For treatment, select only tasks started under the practice version; never relabel historical tasks. Regenerate using a new output filename; the collector refuses to overwrite snapshots. Report collection is explicit, not another scheduled process.

## Pilot

1. Select 3-5 naturally arriving tasks for the baseline arm and 3-5 for treatment with similar difficulty (explicit CohortLabel). Use the same project, repositories, taskType, executionMode, providers, actual/requested models, reasoning and per-role context budgets. No product tasks are launched for the experiment.
   All new manual and automated tasks now persist task.json practiceVersion=spec-practices-1.0.0 at creation, across all configured projects and repositories. The Analyst applies the new templates automatically and must publish the matching analysis version; omitted or downgraded versions are rejected. Standalone agents use the same guides by default. Small fixes keep only relevant sections inline; research-only tasks do not gain delivery phases. Resuming a task preserves its existing version, including legacy tasks with no version field. Baseline tasks must therefore come from genuinely observed pre-default legacy work, not newly relabeled tasks. Missing or mismatched persisted versions cannot form a comparable cohort. Without adequate baseline evidence, report awaiting-data, not a productivity gain. The collector retains its legacy default for historical reports; select the new version explicitly for new-task reports as shown below.
2. Capture v2 baseline before changing practice configuration. Record the task selection and source revision; keep private task evidence outside Git. Missing metadata cannot be reconstructed from today's configuration.
3. Capture a separate treatment snapshot using the same cohort label and explicit task IDs. Never include the same task in both arms. Existing report signatures include provider/model/reasoning per role and budget per role; changed/fallback models split groups. Active/research/metadata-incomplete tasks cannot make a comparable delivery cohort.
4. Run Compare-HarnessEvaluationReport.ps1. It requires matching comparable cohorts and at least three tasks per arm. Quality is 100% linkage/acceptance and zero false completion; failures must not increase per task and artifact/context bytes must not increase over 20%. At least one of elapsed time, tokens or human interventions must improve by 10% for a promising verdict. Missing required observations yield awaiting-data. A small observational pilot establishes no causal or statistical claim.

```powershell
# Choose only tasks actually observed under each practice version.
.\scripts\New-HarnessEvaluationReport.ps1 -TaskIds before1,before2,before3 -PracticeVersion legacy -CohortLabel small-api-feature -OutputPath baseline.json
.\scripts\New-HarnessEvaluationReport.ps1 -TaskIds after1,after2,after3 -PracticeVersion spec-practices-1.0.0 -CohortLabel small-api-feature -OutputPath treatment.json
.\scripts\Compare-HarnessEvaluationReport.ps1 -BaselinePath baseline.json -TreatmentPath treatment.json
```

The initial pre-adoption snapshot found 23 historical tasks, zero eligible complete comparison tasks, and no fully reported token totals. Detailed reports stay local because they contain task identifiers and evidence. Existing v1 collection failed on these artifacts; v2 handles missing legacy fields. The adoption result is **awaiting-data**, not a measured productivity gain. See spec-kit-baseline.json for aggregate provenance and coverage.

## Distribution and rollback

`plugins/development-agent-ecosystem/practice-bundle.json` versions the native skill asset set with SHA-256 checksums and upstream provenance. `Export-PracticeBundle.ps1` validates the manifest and creates a reviewable ZIP with its manifest and the hash-matched skill assets. It never installs a workflow or executes a payload. The existing full plugin installer delivers the skill tree; Install-ChatOnlyAgents copies the same guides for Codex, Claude and Copilot. Runtime Analyst config already selects analyze-requirements; its references load only for the relevant task. Standalone roles remain read-only and return assessments inline.

The byte-pinned assets and collector use explicit LF checkout rules in .gitattributes, so Windows autocrlf cannot silently invalidate a bundle digest or split identical collector revisions into different pilot versions.

For rollback restore the prior practice assets/prompt/configuration revision and reinstall through the normal installer. Keep v2 measurements and both immutable snapshots to assess rollback. Previously generated task artifacts and historical evidence are retained. Existing installation safeguards refuse overwriting locally edited chat-only files; review that diff rather than forcing it. Do not enable speckit workflows, implementation/bug-fix commands, git hooks, shell steps or community extensions as part of this package.
