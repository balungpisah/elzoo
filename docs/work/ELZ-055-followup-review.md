# ELZ-055 follow-up independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `8de542d551a3d0501508e073ffc2c60da62d9d91`

Inputs: live issue #111 Contract; the revision-2 diff from `4d924c732fae25f274f743a8f67eaaae52bd341d`; `docs/work/ELZ-055.md`; both recorded probe sources; the prior review; the pinned `db_connection` and Carbonite sources; and the ready PostgreSQL Store source, all at the reviewed SHA where applicable.

## Findings

1. **should-fix — “fails closed by construction” is too broad for a residue that remains on a reusable connection.**
   - Location: `docs/work/ELZ-055.md` lines 28, 145–153, and 210–219; `docs/work/ELZ-055-probes/carbonite_fit_spike_test.exs` lines 304–368.
   - Problem: the cited pinned `DBConnection.ConnectionPool` source does support the stated holder-death behavior: on `ETS-TRANSFER` for a dead client it calls `Holder.handle_disconnect/2`, so the P3 result is credible for the required production pool. The probe also correctly covers commit and rollback, and a pinned checkout prevents simultaneous use of that connection. But an exact stream-and-digest append binding is reusable for the same uncommitted record after rollback if a different pool returns a still-live connection; likewise a retained range remains authority for exactly that range. That is not attribution of a record outside the declared data binding, but it can attribute a later retry by another command to the earlier session. Thus the mechanism itself is not universally fail-closed; it is fail-closed under the explicitly required `DBConnection.ConnectionPool` disconnect contract.
   - Concrete change: replace the unqualified construction claim with that conditional statement in the resolution and P3 conclusion. Keep the other-pool exclusion as a hard production Need, and make the final Piece reject or explicitly document unsupported ownership/sandbox pools rather than implying the digest binding alone closes their stale-setting path.

2. **should-fix — P1.7 claims coverage of every pooled connection that the assertion does not establish.**
   - Location: `docs/work/ELZ-055.md` line 169; `docs/work/ELZ-055-probes/carbonite_fit_spike_test.exs` lines 264–265.
   - Problem: the source asserts six sequential checkouts have an empty setting, but it does not collect or distinguish backend identities. A pool may hand the same connection to all six calls, so this is not an assertion that each of six connections was observed. The other P1 table entries inspected have corresponding assertions, including conservative refusal, unchanged state, TRUNCATE, disabled-trigger behavior, and the retention range check.
   - Concrete change: either say “six post-write checkouts” or hold six checkouts concurrently, record distinct backend identities, and assert an empty setting on every one before retaining the stronger table wording.

3. **should-fix — the planned security-definer evidence must assert the fixed path and safe owner, not only `prosecdef`.**
   - Location: `docs/work/ELZ-055.md` lines 154–157, 239–241, and 335; `docs/work/ELZ-055-probes/carbonite_fit_spike_test.exs` lines 89–129 and 372–443.
   - Problem: the proposed privilege model is sound in principle: the audited-table trigger is fixed, the supplied attribution JSON is data rather than executable SQL, the application role cannot alter Carbonite configuration, and functions run with `pg_catalog, pg_temp` fixed. Under the stated dedicated non-superuser audit-owner Need, this does not expose a privilege-escalation path through application-controlled attribution values. The recorded P4 exercise, however, uses a privileged probe owner and verifies neither function owner nor `proconfig`; its announced future assertion of `prosecdef` alone cannot establish the fixed search path, and a later Carbonite migration can replace the function attributes.
   - Concrete change: make T14 query and assert, for both functions, `prosecdef`, the exact `search_path` configuration, and ownership by the dedicated non-superuser audit role; rerun that assertion after every migration path that can recreate Carbonite functions. Retain the no-schema-privilege and refused-DML probes as finite application-role evidence.

4. **note — the AshPaperTrail comparison is credible and appropriately bounded.**
   - Location: `docs/work/ELZ-055.md` lines 176–197; `docs/work/ELZ-055-probes/ash_paper_trail_probe_test.exs` lines 154–180.
   - Problem: the source exercises the ready Store append against the same record table, asserts zero versions, then asserts that an Ash create makes a version while bypassing the Store head, CAS, and digest path. It is a generic Store-layer exercise rather than the complete owner flow, but the record says that and limits the conclusion to this caller.
   - Concrete change: none; keep T6 as the separate evidence for the complete effect-intent owner path.

5. **note — evidence categories, Config treatment, and the amendment package are precise.**
   - Location: `docs/work/ELZ-055.md` lines 312–363 and 77–124; live issue #111 admission record item 2.
   - Problem: proof, type/schema checking, tests, monitored behavior, upstream contracts, and assumptions are now separated; the Config table states owner, bounds, default, timing, and named tests. The live body is 6,623 bytes with SHA-256 `919b084dfa9770da0d54a89435b64d832634adc4a70cbac5776cb424a8b17f7f`; each A1/A2 Before occurs exactly once, and applying both replacements yields the recorded 7,021-byte SHA-256 `4454bb342db8a575286035e45bb9002c11f6a6dae744f3cfb888eb2b7130ede6`. A1 implements the prior finding’s required session-initiating action, opaque declared Need, first audited surface, and exclusion scope; A2 puts the typed refusal at binding.
   - Concrete change: none.

## Earlier-finding dispositions

- B1 provider comparison: **resolved**.
- B2 session-setting leak: **partly resolved**; P3 resolves it for the required production pool, but the construction claim needs the condition in finding 1.
- B3 asserted P1 evidence: **partly resolved**; assertions were added, with the P1.7 coverage wording correction in finding 2.
- S4 application-role privilege boundary: **partly resolved**; the design and P4 role exercise are sound finite evidence, with T14 completion in finding 3 still required.
- S5 binding attribution semantics and scope: **resolved** by A1/A2.
- S6 evidence and operational precision: **resolved**.

## Verdict

**Proceed after fixes.** There are no blocking findings; address the three scope/evidence corrections before treating the revised record as final readiness evidence.
