# ELZ-055 — Specify the attributable audit log for the effect-intent decision record

- Phase: demand-led state policy
- Catalogue IDs: state/audit-log
- Dependencies: ELZ-009, ELZ-023

## Outcome

Own an attributable, retained audit record that commits or rolls back together with the
mutation it describes, with the ELZ-023 effect-intent decision record in its PostgreSQL
Store as the first audited mutation. Compare `carbonite` 0.17.0 (Apache-2.0) with
`ash_paper_trail` 0.8.1 (MIT) by exercise on that mutation and adopt the one whose
transaction boundary fits the ready Store; author only the attribution contract, the
exclusion and retention policy and the evidence. This is the fourth task of the owner's
batch (decision record: `docs/plans/catalogue-dispositions.md#state-audit-log`; owner
answer 5).

## Admission record

1. **Responsibility and caller.** Record who did what to which record with which outcome,
   atomically with the mutation. Callers: the ELZ-023 decision record first; then C1
   membership activation, C3 refund approval and C6 publication approval as they are
   admitted.
2. **Interface and invariant.** Inputs: the audited mutation performed through the ready
   Store (`state/event-log` over `integration/sql`), an attribution input (actor reference,
   action kind, reason) supplied explicitly by the caller because the effect-intent record
   carries no actor field and `domain/principal` is deferred, bound once per Store binding
   (session): the actor reference is opaque and validated for shape only (a declared Need),
   the action is the session's initiating business action, not a per-command action, and the
   attribution applies to each audited `elzoo_log_records` change made through that binding
   (checkpoints, heads and outbox state are outside this first audited surface), an exclusion list of
   sensitive fields, and a retention rule evaluated by a pure function or a Store query
   that the caller invokes; this task adds no job type, no Oban worker and no scheduler. Outputs: an audit row per committed mutation
   with actor reference, action, record identity, before/after of non-excluded fields,
   transaction identity and timestamp; a typed refusal when attribution is absent at binding. Invariants:
   the audit row and the mutation commit or roll back together; a mutation without
   attribution is refused, never recorded as anonymous; excluded fields never appear in an
   audit row; audit rows are append-only under the application role; retention is explicit
   and dated, and its evaluation is a pure function or a caller-invoked Store query, not a
   scheduled job. Non-goals: capturing denied actions or no-mutation decisions (a separate
   explicit path), TRUNCATE or privileged bypass detection, universal tamper proofing,
   telemetry, metering.
3. **Reuse check.** `carbonite` captures changes transactionally through PostgreSQL
   triggers and metadata; `ash_paper_trail` versions Ash resources. The ready Store is not
   an Ash resource, so Carbonite is the expected fit, but its trigger must fire inside the
   Store's own transaction: the ready `integration/sql` Store refuses Store calls inside a
   caller transaction and commits Writer calls independently (its README). Whether a
   Carbonite trigger and its transaction metadata work within that boundary is the
   provider-fit gate of this task and is decided by exercise, not assumption. Elzoo owns
   the attribution contract, exclusions and retention; Carbonite's own outbox is not a
   second `state/outbox`.
4. **Split test.** Attribution and capture stay behind one interface, because an audit row
   without attribution has no value and attribution without atomic capture is a claim.
   Denied-action recording is a separate path admitted later.
5. **Failure and evidence.** Dangerous paths: an audit row committed without its mutation
   or a mutation without its row; missing attribution recorded as anonymous; an excluded
   sensitive field captured; a concurrent change attributed to the wrong actor; trigger
   bypass by TRUNCATE or a privileged role (disclosed limit, not a guarantee). Proofs: none
   required. Tests on PostgreSQL in the worker's own database: commit pairs row and
   mutation; rollback removes both; missing attribution refused; excluded field absent;
   two concurrent mutations attributed correctly; the ELZ-023 decision record's actual
   write path produces exactly one audit row; TRUNCATE and privileged bypass documented by a
   test that shows the limit; the retention query selects only rows past the rule. Upstream:
   PostgreSQL trigger and transaction semantics and Carbonite's capture are named, not proved.
6. **Composition record.** Depends on `delivery/effect-intent`, `integration/sql`,
   `state/event-log` (ready); `domain/principal` is deferred, so the actor reference is an
   explicit input and the record's open question is closed by this choice for the first
   caller. Telemetry `not_applicable` (audit is not observation); Config `supported` for
   exclusions and retention; Control `not_applicable`. No authority, approval or billing
   semantics.

## Scope

- exercise `carbonite` 0.17.0 and `ash_paper_trail` 0.8.1 against the ELZ-023 decision
  record write path and record the comparison; adopt one and record the reason;
- add `pieces/state/audit-log/` with the attribution contract, exclusion policy, the
  retention rule as a pure function or caller-invoked Store query (no job type, Oban worker
  or scheduler), migrations for the audited Store schema, README, `piece.json` and tests;
- add the adopted library at its pinned version to `registry/providers.json` with license;
- promote `state/audit-log` in its own catalogue row and release-plan entry, regenerate
  `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Commit and rollback pair the audit row with the mutation on the ELZ-023 write path.
- [ ] Missing attribution is refused; excluded fields never appear; concurrent mutations
      are attributed correctly.
- [ ] The TRUNCATE and privileged-bypass limits are shown by tests and stated in the README.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite PostgreSQL tests over the listed scenarios; upstream contracts for PostgreSQL
triggers and the adopted library; no proof is claimed. Attribution comes from an explicit
caller input until `domain/principal` exists; denied actions and no-mutation decisions are
not captured; no universal tamper-proof claim.

## Out of scope

Denied-action records, telemetry, metering, Ash resource history for non-Store data,
retention beyond the declared rule, a second outbox.

## Reference

Decision record `state/audit-log` (ADOPT; owner answer 5); ranking R15; awesome-elixir
report rows `carbonite`, `ash_paper_trail`, `paper_trail`; ELZ-050 review R1 on the Store
transaction boundary and the missing actor field.
