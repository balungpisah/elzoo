# ELZ-098 — Specify bounded correlated joins over declared branch results

- Phase: demand-led delivery policy
- Catalogue IDs: delivery/aggregation
- Dependencies: ELZ-003, ELZ-006, ELZ-026, ELZ-033

## Outcome

Deliver `delivery/aggregation`: a bounded join that collects delivery results
for a declared set of branch identities and produces one explicit decision —
`pending`, `all`, `partial`, `failed` or `expired` — with every branch's
outcome visible by its declared identity. Identity comes from declared
branch identity carried in the Envelope result's correlation/attempt/value
fields, never from arrival order or position. A volatile fan-in runner over
`Task.Supervisor` is included for callers without durable branches;
durable fan-out stays with `workflow/run` (out of scope).

## Decisions this task carries

- Disposition WRAP reconciled: OTP `Task.Supervisor`/`async_stream` supplies
  volatile fan-in mechanics; Reactor is not adopted (no durable saga caller
  exists). Correlation and completion policy are Elzoo's — authored here.
- Study inputs applied (ELZ-025 round-2): theory_craft's positional
  `Enum.zip` join is the negative test — identity is never arrival order;
  lux's killed-branch drop is the negative test — a killed or timed-out
  branch is recorded `timed_out`/`unknown` per the Envelope result matrix,
  never omitted; pixir's denial aggregation is the negative test — "no
  denials" is distinct from "denial record unreadable", so a branch whose
  evidence cannot be read is `unavailable`/`missing`, never a zero count.
- Each expected branch contributes at most once: the first accepted result
  per branch identity stands; later results for a settled branch are recorded
  `duplicate` (payload compared — a differing outcome/value marks the branch
  `conflicted`) and never merged. Results for undeclared identities are
  refused, keeping state bounded by the declared set.
- No new dependency: the join is pure policy (Cure-suitable); the volatile
  runner uses OTP `Task` under an injected supervisor.

## Admission record

1. **Responsibility and caller.** Join declared branch results into one
   explicit, bounded decision. Callers (RC-15): C5 dependants notification,
   C6 collect child results. `core/envelope` owns the result schema;
   `delivery/retry-timeout`/`delivery/time` own deadline and clock vocabulary;
   `workflow/run` owns durable branches (not this Piece).
2. **Interface and invariant.**
   - *Construction.* `new/2` takes `declared` — the expected branch
     identities (bounded list, `max_branches` cap, duplicates in the
     declaration refused) — and `config` — a `branch_key` spec naming where
     branch identity lives in a validated Envelope result (`{:field, path}`
     over `correlation_id`, `attempt_id`, or a declared `value` field —
     configured per caller, never positional), a deadline
     (`deadline_unix_ms` or explicit `:unbounded`), per-branch result size
     bound (measured on the encoded result term), and a clock port. Invalid
     or oversized declarations are refused at construction.
   - *Inputs.* `accept/2` takes one Envelope result (validated through
     `core/envelope`'s `decode_result`/`validate_result` — malformed input
     is `{:error, :invalid_result}`, never partially merged); it reads the
     injected clock, so a result arriving at or after `deadline_unix_ms` is
     recorded `late` immediately and never merged — deadline enforcement
     does not depend on the caller invoking `decision/2` on time.
     `mark_lost/3` records `{:timed_out | :killed | :unavailable,
     branch_id}` — a **first-class loss record**, not a synthetic Envelope
     result; `status/1`/`decision/2` expose records without payloads.
   - *Outcome mapping.* An accepted Envelope result maps to branch status
     by its `outcome`: `completed` → `fulfilled`; `rejected` → `failed`;
     `failed` → `failed`; `timed_out` → `timed_out`; `unknown` →
     `unavailable` (possibly dispatched, evidence unreadable — never a
     zero). The result's `dispatch` and `error_class` fields are preserved
     on the record. `mark_lost` kinds map directly: `timed_out`/`killed`/
     `unavailable`.
   - *Branch record.* `%{status, result | loss, duplicate_count,
     conflicted, late_count, first_seen_unix_ms, decided_unix_ms}` with
     `status ∈ {:pending, :fulfilled, :failed, :timed_out, :killed,
     :unavailable, :missing, :conflicted, :late}`.
   - *Decision.* `decision/2` is a pure transition returning
     `{join', outcome}`: `:pending` while any branch is pending and the
     deadline has not passed; `:all` when every branch is `fulfilled`;
     `:partial` when at least one branch fulfilled and at least one is
     terminal non-fulfilled (failed/timed_out/killed/unavailable/missing/
     conflicted); `:failed` when no branch fulfilled and at least one is
     terminal; `:expired` when the deadline passed with branches still
     pending — the transition records pending branches `timed_out`/
     `missing` and closes the join in the returned state (the caller
     persists the plain-map state). Once closed, further `accept`/
     `mark_lost` calls are recorded `late` — one late marker per branch
     plus a `late_count`, so post-close input cannot grow state.
   - *Invariants.* Every declared branch appears in every decision's branch
     map — omission is a Contract violation, not an encoding choice. Branch
     identity is stable under arrival reordering, duplicate delivery and
     restart (the join state is a plain map the caller may persist through
     the ready Store; serialization is the caller's, the transition is pure).
     State is bounded: `max_branches` declared identities × per-branch size
     bound; no unbounded buffers, no arrival-order state.
   - *Failure taxonomy.* `{:error, :invalid_result}`,
     `{:error, :unknown_branch}` (undeclared identity),
     `{:error, :invalid_branch_key}` (result lacks the configured identity
     carrier), `{:error, :join_closed}` is *not* an error — late input is
     recorded `late`; `{:error, :too_large}` for oversized results;
     `{:error, :invalid_declaration}` at construction. Post-close and
     post-deadline input is always recorded, never an error and never
     merged.
3. **Reuse check.** OTP `Task.Supervisor`/`async_stream` (already available)
   for the volatile runner; `core/envelope` result validation (ELZ-003);
   `delivery/time` clock port and `delivery/retry-timeout` deadline
   vocabulary (ELZ-006). `reactor` 1.0.7 (the disposition's surveyed library)
   is not adopted: no durable saga caller exists and its Contract would add
   a runtime this Piece does not need. `delivery/resequence` (planned,
   RC-28) is a different mechanism — ordered streams, not result joins.
4. **Split test.** The join decision, branch records and volatile runner
   share the "declared identity, bounded state, explicit outcome" invariant.
   Envelope validation, clocks, deadlines, durable execution and worker
   retries are separate ready Pieces or consumer duties.
5. **Failure and evidence.** Dangerous paths (RC-15 acceptance): duplicate
   result (recorded, first stands, conflict flagged when payloads differ);
   absent/killed branch (`mark_lost` → `timed_out`/`killed`/`unavailable`
   recorded with dispatch preserved); late result after terminal decision
   (`late`, never merged); timeout (`:expired` with pending → `timed_out`);
   unreadable/missing evidence (`unavailable`/`missing` — never a zero or an
   omission); conflicting duplicate (branch `conflicted` → decision
   `:partial`); undeclared branch result (refused); oversized result
   (`:too_large`, branch stays pending → deadline path); declaration with
   duplicate identities (refused at construction). Tests: pure transition
   scenarios over a controllable clock plus volatile-runner tests with real
   `Task`s (success, exception → `failed`, deadline kill → `timed_out`,
   duplicate branch ids in the run declaration refused). No proof is
   required; the transition is table-testable.
6. **Composition record.** Piece dependencies: `core/envelope` (ELZ-003),
   `delivery/time` clock port (ELZ-006); ELZ-026's dependency-readiness
   vocabulary is consumed only where a caller's wiring needs it — the join
   itself reads envelope results and a clock. Needs: none for the pure join;
   a `Task.Supervisor` for the volatile runner (injected — the Piece starts
   none and requires no Application). Telemetry: `planned` at publication —
   bounded decision/outcome events only, no result payloads; upgraded to
   `supported` with event tests at readiness if events ship. Config:
   `supported` at construction (bounds, branch key, deadline policy).
   Control: `not_applicable` — the join is a value, not a lifecycle;
   pausing is the caller's concern. Data classification: branch results are
   consumer data — never logged; branch ids, statuses and counts may appear
   in telemetry.

## Scope

- add `pieces/delivery/aggregation/` with README, `piece.json`, `lib/`
  (join Operator plus the volatile runner as a separate module), `cure/`
  (the decision transition if it earns a law — identity determinism and the
  at-most-once-per-branch bound are the candidate laws), `test/` and
  examples;
- publication duties on the task branch (main's publication step already
  created the issue): create `tasks/ELZ-098-delivery-aggregation.md`
  byte-equal to the live issue body; add release-plan job `ELZ-098` (paths,
  dependencies, `issue_body_sha256` of the live body, outputs
  `["delivery/aggregation"]`, plus `kind`/`release`/`stage`/`product_aims`
  carried from RC-15 — P07); move the `delivery/aggregation` entry's `job`
  from `RC-15` to `ELZ-098` and mark RC-15 superseded for this output; run
  `mix elzoo.ledger`; regenerate `LEDGER.md` and roadmap views;
- at readiness: registry row, `piece.json` manifest hashes, operational
  declarations, consumer-layout test;
- no dependency change expected; worker gate `mix check --affected
  origin/main` + `mix test pieces/delivery/aggregation/test` before every
  push.

## Acceptance

- [ ] `new/2` refuses duplicate/oversized declarations and invalid branch-key
      specs; `accept/2` validates results through `core/envelope`, refuses
      unknown branches and oversized payloads, and records post-deadline
      input `late` using the injected clock without needing `decision/2`.
- [ ] Every decision's branch map covers exactly the declared identities;
      `decision/2` returns `{join', outcome}` with `pending/all/partial/
      failed/expired` per the recorded scenarios, performs expiry recording
      and close in the returned state; outcome→status mapping matches the
      declared table; a closed join records late input with bounded
      `late_count`.
- [ ] RC-15 scenarios pass: duplicate result (first stands, conflict
      flagged), absent/killed branch recorded with dispatch preserved, late
      result marked, timeout → `expired`/`timed_out`, unreadable evidence →
      `unavailable`/`missing` distinct from zero; each expected branch
      contributes at most once.
- [ ] Branch identity is stable under arrival reordering (test shuffles
      arrival order, identical decision); state round-trips through a plain
      map for caller-side persistence.
- [ ] Volatile runner: declared `{branch_id, fun}` pairs execute under the
      injected supervisor; exception → `failed`, deadline → `timed_out`,
      duplicate ids refused, no retries, results feed the same join.
- [ ] No result payload, branch payload content or secret in telemetry,
      errors or inspect values; the Piece reads no environment variables.
- [ ] Operational applicability declared per docs/operational-contracts.md.
- [ ] Piece tests pass in the exported consumer layout; the root Application
      is not required.
- [ ] Full hosted `symbolic-check.yml` green on the exact PR head; local
      worker gate recorded with exit codes.

## Evidence and limits

Finite tests over the listed scenarios; pure transition tests; volatile
runner tests over real `Task`s; upstream contracts of OTP `Task.Supervisor`,
`core/envelope` result validation and the clock port. No claim of durable
join state (the caller persists the plain-map state through the ready Store
if needed), no exactly-once branch execution (the runner is at-most-once per
call, volatile), no ordering guarantees across branches, no workflow-timer
or saga semantics, no guarantee that a branch's own retries preserve its
identity (the branch Contract owns that; the join keys on the declared
identity carrier).

## Out of scope

Durable fan-out and saga execution (`workflow/run`), ordered/streaming
joins (`delivery/resequence`, planned), map/reduce-style aggregation of
payload values (the join reports per-branch results; value combining is the
consumer's), branch scheduling or retry policy, Reactor or any join
framework, cross-join queries over stored results.

## Reference

RC-15 contract and acceptance ("Declared branch identities plus correlated
results -> bounded join state and explicit all/partial/failed/expired
decision. Arrival order is not identity; retention and duplicate policy
explicit … Each expected branch contributes at most once");
`docs/plans/catalogue-dispositions.md#delivery-aggregation` (WRAP; OTP
Task.Supervisor for volatile fan-in; Reactor only for a durable saga caller);
ELZ-025 round-2 studies — `docs/research/studies/round-2/finance.md`
(theory_craft positional join, negative), `frameworks.md` (lux killed-branch
drop; fan-out join design tests), `pixir.md` (zero-vs-unavailable); owner
decision OD-A.

## Open questions (none blocks a builder)

1. Whether the volatile runner's killed branches feed `mark_lost` records
   or synthetic Envelope results; resolved at admission: `mark_lost` records
   are first-class (the runner maps its kills to them), keeping the Envelope
   matrix clean.
2. Whether `conflicted` branches make the overall decision `:partial` always
   or only when no `:all`-eligible reading exists; recommended: `conflicted`
   is terminal non-fulfilled → `:partial` (or `:failed` when nothing
   fulfilled), recorded either way.
3. Whether the volatile runner lives in this Piece or defers to consumers
   using `Task.async_stream` directly; recommended: include the thin runner
   — the disposition's WRAP names it and the deadline/kill path is exactly
   the policy worth centralizing.
