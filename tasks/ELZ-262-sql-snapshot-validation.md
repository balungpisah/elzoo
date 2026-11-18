# ELZ-262 — Validate SQL snapshot rows after the Store transaction

- Dependencies: ELZ-193, ELZ-232
- Output: none. A repair inside the ready Piece `integration/sql`; its Contract and Piece ID stay unchanged.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/integration/sql/**` only, plus the section 3 index/generated changes required if `piece.json` changes.
- Publication: publish this as a distinct task before implementation. Do not reuse another task or Piece ID.

## Outcome

`read/4` and `read_at/3` fetch the head and raw rows in their existing Store-owned, repeatable-read, read-only transaction. Once that transaction returns, they validate the captured rows with the existing `record/2` logic, including digest/hash checks, inside the existing never-raise and error-mapping boundary. Release a checkout owned by that Store transaction before this pure validation begins.

Do not make a fresh head or row query after the transaction. The returned head and validated rows must come from the same captured snapshot. A checkout owned by the caller is not released by the Store transaction: after the wrapper completes, that caller-owned connection may remain checked out. State this limit in the README and test it.

## Preserved behavior and limits

- Preserve public result shapes, including `{:ok, records, head}`, `{:ok, record_or_absent, head}`, pruned results, and absent/empty reads.
- Preserve `record/2`'s plain-map representation for malformed, corrupt, or oversized rows inside otherwise successful read results; these ordinary invalid-row outcomes do not fail the whole read.
- Preserve query text, order, count, arguments and repeatable-read snapshot: transaction begin, read-only repeatable-read setup, head query, raw-row query, commit. The validation phase adds no SQL.
- Preserve the caller-transaction refusal, raw-`BEGIN` behavior, `test_read` hook, existing error normalization, and the direct one-statement read paths.
- Preserve the default and configured Store timeout values, writes and digests. Keep the existing timeout on the Store-owned transaction; pure validation after that transaction is not an end-to-end timeout. Do not increase a timeout, add a public callback/option, redesign paging, add a generic pipeline, or claim the whole read pipeline is bounded by 5 seconds.
- Keep unexpected exceptions or throws during mapping inside the existing Store read helper's rescue/catch boundary and normalize them to its existing read error result. Build the complete result before returning success so no partial list escapes on such an unexpected failure.

## Evidence and limits

A temporary one-run timing probe observed a 994-row read with 538,957,896 raw payload bytes, a 1,902,100-byte maximum payload, a 2,594,817 µs head-and-row SQL phase, and `repo.checked_out?() == true`. The subsequent 5000 ms timeout stack was in `:crypto.hash_update/4` through `DurableLog.validate_row/3` and `Postgres.record/2`; no validation elapsed value was captured for that failing call. Seven other completed 994-row reads in that instrumented launch measured 861,429–1,124,341 µs SQL and 1,295,397–2,836,974 µs validation.

This is evidence that a timeout can occur after the SQL fetch while validation is active. It does not show that hashing alone caused the observed local aggregate failure: the failing call's validation duration and full transaction elapsed time were not measured, the transaction timeout also includes work before the measured fetch phase, and the diagnostic pass/logging perturbed timing. Do not promise a speedup, a fixed validation time, or a 5-second end-to-end bound.

## Named acceptance groups

1. **Store-owned and caller-owned checkout state**: with real PostgreSQL, successful `read/4` and `read_at/3` validation begins after the Store transaction has returned. At the test observation point, assert `repo.in_transaction?() == false`; when the Store owned the checkout, also assert `repo.checked_out?() == false`. Under an explicit caller-owned `Repo.checkout/2`, assert the transaction is over but `repo.checked_out?() == true`; do not claim the caller's checkout was released. Existing caller-transaction refusal and raw-`BEGIN` protections remain unchanged.
2. **One snapshot, same query sequence**: use Repo query telemetry to assert the existing begin, `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY`, head, raw-row, and commit sequence/count for both reads, with no query during validation. Through one invocation of the existing explicit `test_hook` seam, permit a single `:after_snapshot_before_validation` pause after the Store transaction returns. Use a legal retention setup on a separate fresh stream for each read: append two valid records with no outbox items, persist a valid checkpoint at sequence 1 using the existing checkpoint helper, then start `read/4` from sequence 1 with limit 2 or `read_at/3` for sequence 1. While each read is paused, append sequence 3 with expected revision 2, then retain with expected low-water 0 through sequence 1. The checkpoint anchors retention and the absence of pending outbox items allows it to commit. Resume and assert the captured head and rows/record are returned even though retention advanced low-water and removed sequence 1; no fresh lookup is allowed. Cover empty, absent and pruned results.
3. **Rows and errors**: preserve corruption/digest, malformed-row, and oversized-row behavior. Ordinary invalid rows remain plain maps in successful read results. Separately exercise an unexpected exception or throw during mapping: the existing Store read helper normalizes it to its established read error result, and no partial list escapes.
4. **Negative control**: temporarily move the same validation and phase observation back inside the original transaction. The phase assertion that transaction state is false must fail. Restore the exact production source after the control. An optional snapshot-splitting control is not required unless it provides a useful deterministic failure.
5. **Unchanged consumers**: leave RunEngine source and tests unchanged. In one focused seed-0 trace launch, run `mix test --exclude test --include line:9124 --include line:9157 pieces/assembly/run-engine/test/elzoo/run_engine_test.exs --seed 0 --trace --repeat-until-failure 2`. If green, require all three suite executions (six selected test executions). Run the full SQL Piece test module and the copied SQL consumer using the existing export test, `mix test test/export_test.exs --only consumer_id:integration/sql`. Also run the selected native pair once in a disposable, dependency-closed copied `assembly/run-engine` consumer using existing export facilities, not a new exporter or root harness. Verify SHA-256 equality for copied `test/elzoo/run_engine_test.exs` and `test/support/run_engine_test_helper.exs` against their source files. Verify the copied test VM resolves `Elzoo.RunEngine` inside the copied consumer and has no root-repository `ebin` loaded. Run relevant unchanged native cases through the dependent-Piece tests in the small gate.

## Documentation, checks, and acceptance

Update the SQL README and test grounding to explain that the Store snapshot transaction covers head/raw-row fetch, while row validation happens after that Store transaction. Explain that a caller-owned checkout remains caller-owned. Make no speed guarantee. If `piece.json` grounding changes, update only the section 3 indexes/generated files required by that manifest change; keep the existing Piece ID.

Before the database-backed Piece gate, run and capture the cheap source, format, compile, roadmap, live-roadmap, claims, classifier and diff checks. Then run reusable dependency/database preflight against the exact disposable PostgreSQL 16/vector 0.8.7 target used by the gate. Run `mix check --piece "$(git merge-base origin/main HEAD)"` so ready dependents and existing exported consumers are included, followed by `git diff --check`. Capture command, mutation, source hash, exit and wall time from the first run; retain failures and raw diagnostics privately, without bindings or database identifiers.

Require a separate exact-diff review, exact-head hosted `check-piece`, and ready merge-queue completion. Do not accept aggregate/Wave 4 completion until the full-main result completes. Close reporting issue #600 only as part of implementation completion; do not claim this repair proves the cause of the observed local aggregate failure. ELZ-260, ELZ-258, #584, and Level 4 work remain out of scope.
