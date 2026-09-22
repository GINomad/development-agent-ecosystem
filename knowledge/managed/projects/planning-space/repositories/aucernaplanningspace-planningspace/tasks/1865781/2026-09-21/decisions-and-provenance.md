# Authoritative decisions and provenance
User decisions, 2026-09-21:
- Preserve all analysis context for implementation in coming months; preservation is not implementation authorization.
- Desktop code and reproducible behavior are the authoritative business-semantic baseline. Port existing behavior into web; incomplete mockups/conflicting descriptions do not introduce a new contract.
- Optimistic means desktop parity. Pessimistic means original description interpretation including new Discount Rate cell input. They are scope scenarios, not statistical bounds.
- Linear estimates, no Fibonacci: 2 SP = 1 person-day. Analysis assumes an 8-hour day, hence 1 SP = 4 hours.

Provisional planning figures, not verified effort or delivery commitments:
Optimistic four PBI 376 hours/94 SP; full feature 768 hours/192 SP.
Pessimistic four PBI 408 hours/102 SP; full feature 800 hours/200 SP.
Difference 32 hours/8 SP is the alternative Discount Rate scope. Active implementation baseline remains desktop parity. Neighbor 1869308 excluded. Effort includes development, review, focused tests and QA; calendar schedules depend on capacity, holidays, AIDLC/security/deployment allocation.

ADO snapshot 2026-09-21T14:47:46.5734296Z: 1865781 rev59; children 1869322 rev18, 1869334 rev3, 1869339 rev3, 1869369 rev3, no grandchildren. Related 1869308 rev28, 1866883 rev3, 1874388 rev13.
PlanningSpace source HEAD db7f87c7209b5897bba21df7d98a0e0081b58cef; no remote-freshness or new main-product build/test verification.
Conversation decisions are summaries of user instructions relayed by the coordinating agent and reflected in preserved reports, not a claimed verbatim transcript.
Still unresolved: Angular/server-host integration and NFR, product versions/licensing/deployment, persistence and concurrency, migration corpus, ribbon/performance criteria, variable-group dependency and actual capacity.
