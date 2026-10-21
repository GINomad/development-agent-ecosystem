---
name: data-access-and-database-design
description: Plan and review relational schema, EF Core or SQL access, indexes, transactions, concurrency and migrations using the actual repository provider.
---

# Data access and database design

Establish actual provider/version, schema ownership, existing data-access boundary, ORM/query layer and migration system from repository evidence. Do not infer database usage merely because a backend exists. Preserve repository conventions; introduce no speculative database abstraction.

Model keys, tenant ownership, nullability, precision/units, constraints and delete semantics. Choose aggregate/transaction boundaries from business invariants. Prove optimistic concurrency or locking behavior for conflicting updates; process-local locks do not coordinate multiple instances.

For EF Core inspect SQL translation, premature materialization, N+1, tracking, projection, split queries, pagination, query count and cancellation. DbContext is not thread-safe. Do not automatically wrap it in a generic repository. For SQL use parameters and verify query plans/cardinality before recommending indexes.

For PostgreSQL check constraints, foreign keys, partial/composite index predicates, sort order, JSONB semantics and row-level security only where used. Indexes have write/space cost; test representative selective and nonselective cases.

Plan backward-compatible migrations, backfill, locks, rollback/recovery and rollout order. A migration test does not prove production deployment. Reviewer/Verifier challenge cross-tenant access, lost updates, duplicate operations, transaction splits, query growth and destructive migration assumptions.


## Sources and maintenance

Original ecosystem guidance informed by the following upstream skill sources reviewed on 2026-10-21; no third-party skill payload, runtime, hooks or scripts are vendored. Recheck upstream and installed stack versions before adopting changed APIs.

- https://github.com/dotnet/skills/tree/main/plugins/dotnet-data/skills/optimizing-ef-core-queries
- https://github.com/wshobson/agents/tree/main/plugins/database-design/skills/postgresql-table-design
- https://github.com/supabase-community/supabase-plugin/tree/main/skills/supabase-postgres-best-practices
