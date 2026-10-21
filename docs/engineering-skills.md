# Shared engineering and local project skills

The common plugin is project-independent. Requirements Analyst, Developer, Reviewer,
Review Verifier and Knowledge Keeper share architecture-and-pattern-selection,
design-patterns, API/interface design, domain modeling, ADR, Angular, data/database
design, messaging/reliability and testing/observability, alongside the existing
.NET, TypeScript, React and engineering-principles skills. Availability does not
mean loading every skill for every task: use source evidence and relevant scope.

These are original ecosystem adaptations of the sources linked in each skill,
reviewed on 2026-10-21. No third-party runtime, hooks, commands or payloads are
installed. Source popularity aids discovery, while applicability, ownership and
maintenance decide selection. Reassess upstream API guidance against installed
versions; repository-compatible implementation takes precedence over migrations.

## Decisions across roles

Analyst compares the direct/simple implementation with realistic alternatives,
including domain invariants, consistency, ownership, complexity, tests and revisit
conditions. The comparison extends the existing Spec Kit-derived planning guide.
It preserves task practiceVersion, requirementIds, SCN scenarios, ready/held scope
and existing schemas. Small fixes keep this inline.

Developer implements the justified option and reports material deviations.
Reviewer challenges unnecessary abstractions and missed useful boundaries with
concrete observable consequences. Verifier independently falsifies these claims,
including clean reviews, through existing maintainability/correctness/concurrency
coverage. Pattern names alone do not justify a finding. Folder taxonomies follow
evidenced repository conventions rather than a universal layered template.

## Local domain layer

Each configured project uses its domainKnowledgeRoot/skills/<skill-name>/SKILL.md.
Keep domain rules, repository-specific conventions, integration contracts, source
bindings, private examples and task evidence there. Get-ProjectSkillPaths.ps1
discovers these optional skills for the task's repositoryIds; an unrelated or
disabled project contributes nothing. Context packs carry paths and SHA-256
bindings. Revalidate stale facts against the exact repository and revision.
An absent local directory contributes no guessed rules.

Generated runtime Codex roles can discover installed local project skills; they
must consume only task-matched sources. Host-compatible profiles use the same
selection. External PR review uses common reviewer skills and separately prepared,
verified per-PR project context. Standalone installers distribute common skills
only; separately provision local domain skills in the provider's private knowledge
location. Never copy them into a published agent pack.

Project directories are intentionally absent from a fresh remote clone. Restore
them from the owner's local backup or configured local seed source before tasks
that depend on their knowledge. The existing knowledge.versionedRoots name means
revision-bound knowledge sources; it does not authorize Git publication.

## Publication boundary and local migration

config/agents.json is a non-sensitive example. Keep actual organizational URLs,
repository locations, reviewer identities and installation settings in ignored
config/agents.local.json. The default runtime resolves that private file when it
exists; an explicitly selected custom configuration remains authoritative.
Private configuration is backed up with local project knowledge before history
cleanup. Do not copy it into a plugin or published bundle.

.gitignore excludes knowledge/managed/projects, knowledge/local, artifacts and
local JSON. Test-PublicationBoundary.ps1 checks the index or a supplied revision
and rejects private paths even if force-added. Trusted recovery hosts run the
guard after staging and before committing. Run it before any manual publication:

```powershell
./scripts/Test-PublicationBoundary.ps1
./scripts/Test-PublicationBoundary.ps1 -Revision HEAD
./scripts/Test-PublicationBoundary.ps1 -Revision HEAD -History
```

Previously tracked private trees are removed from the index with git rm --cached;
local files are preserved. Before pulling that migration into another existing
checkout, back up its local project trees and restore them after the fast-forward:
Git otherwise removes previously tracked files. Never use git clean -x on the
local knowledge directory. Standard Git deletion does not erase historical
commits; history cleanup is a separate coordinated operation.

After an approved history cleanup, enable the repository-local pre-push guard
with `git config core.hooksPath .githooks`. It checks full ancestry for every
outgoing ref and rejects reintroduction from an old clone even if its tip is
clean. Preserve any existing custom hook configuration before installing.
Other clones must move to the rewritten history before contributing again;
keep private knowledge in a separate backup while doing so.

Validate with tests/Test-ArchitectureSkills.ps1 (role generation, repository
isolation, disabled/unknown projects and a private-publication negative control),
tests/Test-CopilotAgentPack.ps1, tests/Test-SpecificationPractices.ps1 and the full
scripts/Test-AgentEcosystem.ps1 suite.
