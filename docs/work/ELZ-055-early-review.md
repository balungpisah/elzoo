# Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `4d924c732fae25f274f743a8f67eaaae52bd341d`

Inputs read:

- Live issue #111 Contract.
- `docs/work/ELZ-055.md` and `docs/work/ELZ-055-probes/carbonite_fit_spike_test.exs` at the reviewed SHA, plus the diff from `origin/main`.
- `docs/plans/catalogue-dispositions.md`; `docs/operational-contracts.md`; `docs/capability-model.md`; `docs/development/12-change-class-flow.md`; and the repository policy supplied for this review.
- Ready-piece Contracts and implementations for `integration/sql`, `state/event-log`, and `delivery/effect-intent` at the reviewed SHA.
- Installed `carbonite`, `ecto_sql`, and `postgrex` sources where relevant.

## Findings

1. **blocking — provider comparison is not yet the Contract-required exercise.**
   - Location: live #111, Outcome and Scope; `docs/work/ELZ-055.md`, “Comparison: `ash_paper_trail` 0.8.1 (planned exercise, P2)” (lines 121–133).
   - Problem: the issue requires both providers to be compared “by exercise on that mutation.” The draft offers a sound structural hypothesis but labels the Ash test planned and asks to drop it. That cannot close the stated provider comparison or support adoption.
   - Concrete change: run and record the minimal scratch exercise before declaring the provider fit decided: the ready Store `append/5` produces no AshPaperTrail version, while an Ash action that does produce one does not preserve the ready Store CAS/revision/digest path. Keep the commands, pinned versions, finite result, and limit that this is an exercise of this caller, not a general comparison.

2. **blocking — the session-setting design has an unresolved false-attribution failure mode.**
   - Location: `docs/work/ELZ-055.md`, “Attribution source” lines 50–56, “Leaked session setting” lines 179–182, and T11 line 225; probe `attributed/3` and trigger, lines 72–95 and 122–133.
   - Problem: a session-level setting is visible to a later use of the same connection until reset. The ordinary `after` block and P1.7 do not cover a holder death between set and reset. On rollback the trigger’s session-level clearing is restored to the value present at transaction start, so the wrapper reset remains essential. If a checked-out connection returns with the setting, a later matching-stream writer can be accepted and attributed to the prior actor. The planned T11 says its result will decide whether a guard is needed; that leaves the required “never anonymous / never wrong actor” invariant undecided.
   - Concrete change: do not adopt this mechanism until a killing-owner test proves the connection is discarded or scrubbed before reuse, including a later matching-stream write and both commit and rollback paths. If the pool can reuse it, redesign to make leakage fail closed, rather than treating a per-call nonce as a future option; document the named DBConnection/Ecto ownership or reset contract relied on. Keep the existing eight-actor test as finite concurrency evidence only.

3. **blocking — P1’s asserted evidence does not support several “Observed” results or the provider-fit conclusion.**
   - Location: `docs/work/ELZ-055-probes/carbonite_fit_spike_test.exs`, lines 158–181 and 200–212; `docs/work/ELZ-055.md`, lines 98–119.
   - Problem: unattributed, wrong-stream, and override writes are only printed, not matched to their stated indeterminate result or checked for no audit row. The post-checkout setting, TRUNCATE result, and trigger-disable result are also printed only; no write follows the disable to demonstrate the claimed privileged bypass. Consequently one passing ExUnit test does not establish P1.3–P1.9 as reported, and P1 has not exercised the actual `Elzoo.EffectIntent` path that the conclusion calls the ELZ-023 write.
   - Concrete change: make each claimed result an assertion: exact conservative Store result, unchanged head, and unchanged audit rows for every refusal; empty setting after ordinary checkout; no audit change and record removal after TRUNCATE; and a post-disable mutation with no captured change. Retitle the present evidence “generic ready-Store append spike” until T6 exercises the real owner/StoreHost path, then limit the conclusion to those finite scenarios.

4. **should-fix — the application-role append-only design needs a privilege boundary, not only guard triggers.**
   - Location: `docs/work/ELZ-055.md`, “Append-only under the application role” lines 164–169 and Q3 lines 252–254.
   - Problem: the proposed attribution and Carbonite trigger functions insert audit rows as the invoking role unless they are deliberately secured. Granting that role the insert/sequence privileges needed by those functions permits direct fabricated audit inserts; leaving it ungranted prevents legitimate capture. Merely denying UPDATE, DELETE, and TRUNCATE therefore does not demonstrate the intended application-role boundary.
   - Concrete change: use a separate audit-owner/migration role and a safely schema-qualified, fixed-search-path security-definer trigger design, or an equally narrow database mechanism, then revoke direct audit-table DML and audit-schema creation from the application role. The non-superuser test is acceptable and should create a uniquely named, no-login role, verify it is non-superuser/non-owner and has only the stated audited-table privileges, `SET ROLE` for the test, prove allowed append/capture and refused UPDATE/DELETE/TRUNCATE plus direct audit-table mutation, and reliably drop the role on exit. Retain the existing fail-closed effective-database guard before every schema, role, or data effect.

5. **should-fix — per-binding attribution can be an honest new Piece boundary only with narrower action semantics and scope.**
   - Location: live #111, Interface and invariant / Composition record; `docs/work/ELZ-055.md`, lines 38–64 and lines 150–153.
   - Problem: a binding avoids adding attribution inputs to ready `integration/sql`, `state/event-log`, or `delivery/effect-intent`, but one static action and reason are applied to every later write, including asynchronous settlements. That is not an attribution of each caller command’s action. Also, the draft says non-record Store writes pass “unattributed and unrecorded,” which is incompatible with broader wording that a mutation without attribution is refused unless those writes are explicitly outside this first audit surface.
   - Concrete change: have the main coordinator decide and amend the live Contract before implementation: define the explicit input as an opaque, shape-validated binding/session attribution whose action is the session’s initiating business action, not a per-command action; state that it applies to each audited `elzoo_log_records` change in that binding, and list checkpoints, heads, outbox state, and denied/no-mutation decisions as outside this Piece’s first audited surface. The adapter remains a new `state/audit-log` wrapper and does not evolve the three ready Piece IDs. A demand for per-mutation command attribution would instead evolve accepted inputs/Needs of ready Pieces and requires new IDs.

6. **should-fix — the evidence and operational record needs the final Piece-level precision required for readiness.**
   - Location: `docs/work/ELZ-055.md`, Evidence plan lines 208–233 and Operational applicability lines 235–240.
   - Problem: the draft mostly separates proof, tests, and upstream contracts, but “Type/contract check: none beyond compilation” should not imply compilation is a type/contract check. Config is called supported without yet naming its per-Piece test paths, types/defaults/bounds, which the ledger requires; it also mixes migration-time exclusions/prefix, per-binding attribution, and per-call retention without clearly stating when each changes.
   - Concrete change: say explicitly that there is no separate type/schema checker and compilation is only compilation; preserve “Proof: none.” In `piece.json` and README, declare each Config item’s owner, type, bounds/default, and timing, link supported Config evidence to actual in-bundle tests, and keep Telemetry and Control `not_applicable` with their scoped reasons. Retain the upstream PostgreSQL, Carbonite, Ecto/DBConnection contracts and separately list truthful-actor, grants, and database-clock assumptions. Do not claim universal tamper proofing.

## Answers to the requested questions

### Q1 — attribution design

**Recommendation: proceed only after the coordinator narrows and records the binding-attribution Contract, and after the leak test is resolved.** A caller-supplied opaque actor reference is the correct interim Need while `domain/principal` is deferred. Per-Store-binding attribution is honest only as session attribution for every *audited record change*, with a static initiating action/reason; it is not honest if described as the action of every later owner command or asynchronous settlement. Missing/malformed attribution can receive a typed refusal at `AuditLog.bind/3` without changing ready Store replies; the database trigger remains a conservative backstop that surfaces as existing indeterminate failure.

That design is a new `state/audit-log` wrapper and does not change the accepted inputs, Needs, lifecycle, or transaction contract of ready `integration/sql`, `state/event-log`, or `delivery/effect-intent`. It must not be represented as a change to them. Per-mutation caller/action input would change their ready Contracts and needs new Piece IDs.

The pinned checkout avoids sharing a live setting between simultaneous checked-out connections, and the eight-actor probe is useful finite evidence for that scenario. It does not establish safe pool return or a killed holder. A leaked setting can accept a later matching-stream mutation under the previous attribution; therefore the current proposal is not safe until disconnection/scrubbing is demonstrated or the mechanism is changed to fail closed.

### Q2 — audit only `elzoo_log_records`

**Recommendation: accept for the first admitted surface, with an explicit scope statement.** It is the ELZ-023 decision record’s durable event table, and Carbonite changes on that table give a transaction record plus a per-record change. Checkpoints are derived snapshots, heads are bookkeeping, and outbox acknowledgement state is outside the named first mutation. The Contract must say those are deliberately not audited in this Piece, rather than broadly promising an audit row for every Store mutation.

### Q3 — non-superuser test role

**Recommendation: accept, with a fail-closed target guard and a real privilege test.** A uniquely named cluster-scoped, no-login non-superuser role, removed on exit, is suitable to show the application-role claim. Before creating schemas, roles, or data, verify both the configured URL target and `current_database()` against the explicit expected target; then verify the test role is not superuser, not an owner, cannot create roles/databases/schemas, and has exactly the grants needed. The test must prove legitimate captured append and refused direct audit writes and audit UPDATE/DELETE/TRUNCATE; use a separate audit owner and secured trigger function so required capture privileges do not grant audit fabrication.

### Q4 — `ash_paper_trail` comparison

**Recommendation: run the small scratch exercise.** The structural argument is persuasive but the issue explicitly requires comparison by exercise on the ELZ-023 mutation. Record the two outcomes in the task evidence and then adopt Carbonite for this caller; the exercise need not enter the production dependency graph or claim anything about Ash resources outside this path.

## Verdict

**Proceed after fixes.** The proposed new wrapper can preserve ready Piece Contracts and the draft properly identifies exclusions, retention, denied/no-mutation scope, TRUNCATE, privileged bypass, the same-PR dependency departure, and the need for a fail-closed target guard. It must first resolve the session-setting leak, turn the claimed provider results into asserted finite evidence, and complete the required Ash comparison before readiness or provider adoption is claimed.
