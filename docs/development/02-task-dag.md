# Bootstrap task DAG

The files in tasks/ are issue-ready bodies. ELZ IDs are permanent task
identities. Catalogue handles below are the stable IDs from docs/catalogue.md;
the listed assembly work is intentionally partial. A task is ready only after
every dependency ID is merged.

The coordinator can publish a body without a task service, for example:

    gh issue create -R balungpisah/elzoo \
      --title "ELZ-002 — Define contracts and the typed composition boundary" \
      --body-file tasks/ELZ-002-contracts-and-typed-composition.md \
      --label task --label ready --label P0

Use the title/phase appropriate to each body. The files are the publication
input; published issue links are recorded below.

ELZ-001 was accepted during bootstrap after independent clean-checkout and
Linux CI validation. ELZ-013 adds source delivery and a checked ledger.
ELZ-014 clarifies reusable capability boundaries and cross-domain coverage
before ELZ-002. ELZ-015 evaluates the Ash foundation and upstream/fork policy
before those interfaces are extended. ELZ-016 declares operational applicability
and runtime semantics independently of UI/library choices. ELZ-018 resolves
pre-dispatch review conditions; after it merges,
ELZ-002 is the next implementation task. ELZ-017 evaluates Gleam library reuse
independently and
has no runtime dependency on operational contracts. ELZ-018 reviews that
completed baseline before dispatch; it adds no Gleam requirement to ELZ-002.
Workers must not
rebuild or re-open the harness merely because later tasks need it. Report a
new concrete defect as new work, retaining the baseline's evidence and limits.
See [bootstrap validation](07-bootstrap-validation.md).

ELZ-021 decomposes the Raxol reference into admission records. ELZ-022,
ELZ-023 and ELZ-024 are demand-led policy tasks: each depends only on the
foundation tasks listed in its body and none is inserted into the P0–P3
serial chain. Dispatch one when an Assembly needs it, not to fill the queue.

The first batch follows the catalogue phases:

    P0: ELZ-001 -> ELZ-013 -> ELZ-014 -> ELZ-015 -> ELZ-016 -> ELZ-002 -> ELZ-003 -> ELZ-004
    Review prerequisite: ELZ-014 -> ELZ-017 -> ELZ-018 -> ELZ-002
    P1: ELZ-004 -> ELZ-005 -> ELZ-006 -> ELZ-008
        ELZ-003 -> ELZ-007 -------------> ELZ-008
    P2: ELZ-008 -> ELZ-009 -> ELZ-010
    P3: ELZ-010 -> ELZ-011 -> ELZ-012
    Demand-led: ELZ-003, ELZ-004 -> ELZ-022
                ELZ-006, ELZ-009 -> ELZ-023
                ELZ-003, ELZ-015 -> ELZ-024
                ELZ-021 -> ELZ-025
                ELZ-003 -> ELZ-026
                ELZ-003 -> ELZ-027
                ELZ-009, ELZ-010 -> ELZ-028
                ELZ-006 -> ELZ-029
                ELZ-003, ELZ-024 -> ELZ-030
                ELZ-003 -> ELZ-031
    Bug fix: ELZ-009 -> ELZ-032

After ELZ-003, ELZ-007 can run alongside ELZ-004 and the ELZ-005/006 chain.
ELZ-003 owns the shared delivery-result/error/deadline schema before this fork.
ELZ-007 owns selection/routing only; ELZ-006 owns timeout execution, failure
classification and delivery/time changes. Both consume ELZ-003 unchanged;
shared schema changes require a separately reviewed prerequisite task. Registry
entry edits must stay task-scoped; merge registry source and regenerate LEDGER.md
rather than hand-merging generated rows. Thus routing/selection is independent
of the concrete retry/window policies; ELZ-008 integrates those results. Early
foundational tasks remain
serial because they define the interfaces the later agents share.

Detailed edges (direct dependencies; transitive reachability is omitted):

    ELZ-001 -> ELZ-002, ELZ-003, ELZ-013
    ELZ-013 -> ELZ-002, ELZ-014
    ELZ-014 -> ELZ-002, ELZ-015, ELZ-017, ELZ-021
    ELZ-015 -> ELZ-002, ELZ-016, ELZ-021, ELZ-024
    ELZ-016 -> ELZ-002
    ELZ-017 -> ELZ-018
    ELZ-018 -> ELZ-002, ELZ-019, ELZ-021
    ELZ-019 -> ELZ-020
    ELZ-002 -> ELZ-003, ELZ-004, ELZ-007
    ELZ-003 -> ELZ-004, ELZ-005, ELZ-007, ELZ-022, ELZ-024, ELZ-026, ELZ-027, ELZ-030, ELZ-031
    ELZ-004 -> ELZ-005, ELZ-006, ELZ-008, ELZ-011, ELZ-022
    ELZ-005 -> ELZ-006, ELZ-008
    ELZ-006 -> ELZ-008, ELZ-011, ELZ-023, ELZ-029
    ELZ-007 -> ELZ-008
    ELZ-008 -> ELZ-009, ELZ-010
    ELZ-009 -> ELZ-010, ELZ-023, ELZ-028, ELZ-032
    ELZ-010 -> ELZ-011, ELZ-028
    ELZ-011 -> ELZ-012
    ELZ-021 -> ELZ-025
    ELZ-024 -> ELZ-030

| ID | Phase | Catalogue IDs / assembly | Depends on | Tangible outcome |
| --- | --- | --- | --- | --- |
| ELZ-001 | P0 | core/grounding | none | Pinned Mix setup and real mix check harness |
| ELZ-002 | P0 | core/operator, core/port, core/assembly | ELZ-001, ELZ-013, ELZ-014, ELZ-015, ELZ-016, ELZ-018 | Typed pure composition boundary |
| ELZ-003 | P0 | core/envelope, core/edge, core/wiring | ELZ-001, ELZ-002 | Minimal named envelope/port binding and wiring checks |
| ELZ-004 | P0 | runtime/unit, runtime/supervision, runtime/host, runtime/adapter, integration/json, assembly/ingest-dedup-accumulate | ELZ-002, ELZ-003 | Pure/OTP exemplar with Jason boundary |
| ELZ-005 | P1 | delivery/windowed-idempotency | ELZ-003, ELZ-004 | Bounded windowed duplicate policy with explicit limits |
| ELZ-006 | P1 | delivery/backpressure, delivery/retry-timeout, delivery/dead-letter, delivery/time | ELZ-004, ELZ-005 | Capacity, retry and error semantics |
| ELZ-007 | P1 | delivery/request-reply, delivery/routing, delivery/transformation, delivery/stream-combinators, reuse selection | ELZ-002, ELZ-003 | Reuse-first request/routing Pieces and deterministic candidate choice |
| ELZ-008 | P1 | assembly/request-route-retry | ELZ-004, ELZ-005, ELZ-006, ELZ-007 | Working message-resilience Assembly |
| ELZ-009 | P2 | state/event-log, state/outbox, state/checkpoint | ELZ-008 | Durable-state/storage boundary using reuse-first selection |
| ELZ-010 | P2 | state/schema-evolution, state/scheduler, integration/jobs, workflow/state-machine, assembly/durable-job | ELZ-008, ELZ-009 | Narrow durable job Assembly |
| ELZ-011 | P3 | core/effect, integration/http, integration/json, runtime/adapter, assembly/http-job boundary | ELZ-004, ELZ-006, ELZ-010 | One representative external Effect integration |
| ELZ-012 | P3 | core/grounding, clean-check handoff | ELZ-011 | Reproducible clean checkout and scoped evidence |
| ELZ-013 | P0 | Source delivery and provenance across catalogue IDs | ELZ-001 | Selectable source bundles, direct-library recipes and checked ledger |
| ELZ-014 | P0 | Cross-domain capability model and catalogue coverage | ELZ-013 | Source-backed design cases and reuse-first boundaries; no new runtime |
| ELZ-015 | P0 | Ash foundation experiment and upstream/fork policy | ELZ-014 | Isolated action/policy/tool checks and conditional foundation decision |
| ELZ-016 | P0 | Operational applicability and runtime contract experiment | ELZ-015 | Checked declarations and versioned/authorized operational scenarios |
| ELZ-017 | P0 | Independent Gleam library evaluation | ELZ-014 | Isolated Lustre Web Component and shared model checks; no ready export |
| ELZ-018 | P0 | Pre-dispatch contract/evidence hardening | ELZ-017 | Explicit schema ownership, evolution rules and guards; unlock ELZ-002 |
| ELZ-019 | P0 | Development CI execution | ELZ-018 | symbolic-only runner, reproducible job containers and no hosted fallback |
| ELZ-020 | P0 | Development CI capacity | ELZ-019 | Measured BEAM scheduler settings and runner concurrency decision |
| ELZ-021 | P0 | Raxol reference study and admission records | ELZ-014, ELZ-015, ELZ-018 | Pinned design observations, three demand-led task bodies, design tests on ELZ-006/009/010/011; no new runtime |
| ELZ-022 | demand-led | workflow/budget | ELZ-003, ELZ-004 | One-step reserve/settle budget Contract with concurrent-admission evidence |
| ELZ-023 | demand-led | delivery/effect-intent, consumes state/checkpoint | ELZ-006, ELZ-009 | Checkpoint-before-dispatch lifecycle; timeout is unknown, never a blind retry |
| ELZ-024 | demand-led | domain/authorization, workflow/approval | ELZ-003, ELZ-015 | ALLOW/ASK/DENY reducer and payload-bound approval as two Pieces |
| ELZ-025 | P0 | Ecosystem adopt-or-distill study, round 2 | ELZ-021 | Sixteen packages pinned and judged; six demand-led task bodies, design tests on ELZ-009/010/011/022/023/024, reason text; no new runtime |
| ELZ-026 | demand-led | workflow/dependency-graph | ELZ-003 | Pure readiness and cycle admission with provenance-tagged facts |
| ELZ-027 | demand-led | delivery/trigger (schedule occurrence) | ELZ-003 | Occurrence identity and declared overlap policy |
| ELZ-028 | demand-led | state/lease | ELZ-009, ELZ-010 | Revision-fenced single-owner lease; opened only if the job provider's contract is insufficient |
| ELZ-029 | demand-led | runtime/os-isolation | ELZ-006 | OS-process Adapter with group-scoped, observed termination |
| ELZ-030 | demand-led | workflow/context-selection | ELZ-003, ELZ-024 | Bounded, permission-checked selection with drop reasons |
| ELZ-031 | demand-led | domain/money | ELZ-003 | Exact amounts over a closed versioned currency registry; ex_money/Decimal boundary |
| ELZ-032 | P2 | integration/sql (bug fix; same ID) | ELZ-009 | PostgreSQL Store calls inside a caller transaction are refused, restoring the COMMIT-point Contract |

This DAG deliberately does not promise all historical families. If an
Assembly later needs SQL, a broker, replication, CRDTs, AI or another
capability, add a new issue with a new ELZ ID and concrete acceptance. Do not
open placeholder issues merely to reach a row count.

The architecture catalogue says P0's idempotency history is unbounded and
volatile. ELZ-005 uses the separate delivery/windowed-idempotency ID for its
bounded/windowed policy with its own Contract;
it must not rewrite the P0 exemplar's claims or present a local window as
durable or exactly-once delivery.

## Published issues

Live issue state and merged dependencies determine readiness. ELZ IDs stay
stable even when issue numbers differ.

| Task | GitHub issue |
| --- | --- |
| ELZ-001 | [1](https://github.com/balungpisah/elzoo/issues/1) |
| ELZ-002 | [2](https://github.com/balungpisah/elzoo/issues/2) |
| ELZ-003 | [3](https://github.com/balungpisah/elzoo/issues/3) |
| ELZ-004 | [4](https://github.com/balungpisah/elzoo/issues/4) |
| ELZ-005 | [5](https://github.com/balungpisah/elzoo/issues/5) |
| ELZ-006 | [6](https://github.com/balungpisah/elzoo/issues/6) |
| ELZ-007 | [7](https://github.com/balungpisah/elzoo/issues/7) |
| ELZ-008 | [8](https://github.com/balungpisah/elzoo/issues/8) |
| ELZ-009 | [9](https://github.com/balungpisah/elzoo/issues/9) |
| ELZ-010 | [10](https://github.com/balungpisah/elzoo/issues/10) |
| ELZ-011 | [11](https://github.com/balungpisah/elzoo/issues/11) |
| ELZ-012 | [12](https://github.com/balungpisah/elzoo/issues/12) |
| ELZ-013 | [13](https://github.com/balungpisah/elzoo/issues/13) |
| ELZ-014 | [15](https://github.com/balungpisah/elzoo/issues/15) |
| ELZ-015 | [17](https://github.com/balungpisah/elzoo/issues/17) |
| ELZ-016 | [19](https://github.com/balungpisah/elzoo/issues/19) |
| ELZ-017 | [20](https://github.com/balungpisah/elzoo/issues/20) |
| ELZ-018 | [23](https://github.com/balungpisah/elzoo/issues/23) |
| ELZ-019 | [26](https://github.com/balungpisah/elzoo/issues/26) |
| ELZ-020 | [28](https://github.com/balungpisah/elzoo/issues/28) |
| ELZ-021 | [33](https://github.com/balungpisah/elzoo/issues/33) |
| ELZ-025 | [40](https://github.com/balungpisah/elzoo/issues/40) |
| ELZ-026 | [43](https://github.com/balungpisah/elzoo/issues/43) |
| ELZ-027 | [44](https://github.com/balungpisah/elzoo/issues/44) |
| ELZ-028 | [45](https://github.com/balungpisah/elzoo/issues/45) |
| ELZ-029 | [46](https://github.com/balungpisah/elzoo/issues/46) |
| ELZ-030 | [47](https://github.com/balungpisah/elzoo/issues/47) |
| ELZ-031 | [48](https://github.com/balungpisah/elzoo/issues/48) |
| ELZ-032 | [52](https://github.com/balungpisah/elzoo/issues/52) |
| ELZ-022 | [36](https://github.com/balungpisah/elzoo/issues/36) |
| ELZ-023 | [37](https://github.com/balungpisah/elzoo/issues/37) |
| ELZ-024 | [38](https://github.com/balungpisah/elzoo/issues/38) |
