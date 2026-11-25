# ELZ-408 — assembly/run-engine: recover committed Runs on a fresh VM

- Dependencies: ELZ-127, ELZ-387, ELZ-403
- Release: V2; stage `release` under freeze rule 1, so the frozen set does not change.
- Output: no new Piece ID; restore the recovery Contract for [#990](https://github.com/balungpisah/elzoo/issues/990).
- Change class: Piece-only implementation.
- New external dependency: none.
- Owned paths: `pieces/assembly/run-engine/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` as required by a manifest update. No change to `runtime/durable-unit`, `delivery/aggregation`, any other Piece or root code.

## Contract

Unchanged. Before starting or reopening its Unit, the engine loads every module whose engine-owned atoms can appear in its committed records. Audit the actual record shapes the engine writes, including persisted dependency state, to find that set; it includes `Elzoo.Aggregation`. The host does not have to preload engine dependencies. Existing safe-decoding requirements for host-supplied terms (such as pattern-state atoms) still apply. Keep `[:safe]` decoding. Change no record format, control key, start option or written byte: with the same inputs and facts, a record written before and after the repair is byte-identical.

On publication base `e052a9c8`, `RunEngine.init/1` calls `DynamicUnits.start/2` at `run_engine.ex:1656`, before the recovered fingerprint check at lines 1768–1773. The replacement path in `current/1` calls the same start at line 2888. `admit_request/5` stores the join from `Aggregation.new/2` under `control.trackers` at lines 1330–1352. The [failure attribution](https://github.com/balungpisah/elzoo/issues/990#issuecomment-7169574222) identifies `conflicted`, `decided_unix_ms`, `duplicate_count`, `first_seen_unix_ms` and `late_count` in the sequence-4 Unit `"result"` row for `"start"`. With those atoms absent, `DurableUnit`'s `:erlang.binary_to_term(bytes, [:safe])` at `durable_unit.ex:265` fails, `DynamicUnits.start/2` reports `{:error, :start_failed}`, and `RunEngine.start_link/1` reports `{:error, :invalid_options_or_recovery}` before comparing options. The existing restart helper (`run_engine_test.exs:5949–5954`) restarts the processes but stays in the writing VM.

Owner decision (2026-11-25): repair in place and refreeze. After this repair merges, the freeze baseline and X1–X3 fixture tasks move to this task's merge in a separate coordinator-decision change. Do not move them in this task.

## Acceptance

- On disposable PostgreSQL, write each scenario in one BEAM and recover its committed rows in a separate fresh BEAM. Use an OS-process Mix run or a `:peer` node, as supported by the test setup. Cover completed default v1 (omit `protocol_version`), paused explicit v1 with `expiry_reports: :owner`, and open v2 with `messages: :while_active` and a valid `event_source`. The reader BEAM must not exercise a writer or otherwise preload the engine dependency atoms under test before recovery. With matching options, `RunEngine.start_link/1` succeeds and `status/1`, scoped `transcript/3` and scoped `result/3` equal the recorded values. The completed result retains its payload; the paused and open results are `{:pending, :not_completed}`. The open Run accepts another `input/4` and advances (the captured scenario's verified v2 cancel produces terminal `:cancelled`). On the same pre-recovery rows, adding `expiry_reports: :owner` to the completed case, removing it from the paused case, or removing `messages: :while_active` from the open case returns `{:error, :incompatible_recovery}`. Keep those mismatch checks independent of the extra input.
- Keep the histories from #990: the paused Run has an owner expiry, and the open v2 Run has received a message while an event wait was active. Merely turning on the options does not cover these histories.
- Atom audit: in a fresh BEAM with the ordinary host setup and only the engine's own dependency-loading step, decode every captured Unit record payload with `:erlang.binary_to_term(bytes, [:safe])`. Do not deserialize an outer fixture or expected value in a way that interns the atoms before this assertion.
- Byte identity: compare the ordered committed Unit records and completion-evidence records written by the repaired engine against the frozen engine for identical scenarios and fixed facts, before the extra recovery input. The unchanged captures and their three pinned digests on `task/ELZ-406` at [`911c1f9b`](https://github.com/balungpisah/elzoo/commit/911c1f9b9fa457104feda2007f55a369b18497e4) may serve as the baseline; the digests pin the fixture files, so compare the rows inside them or reproduce the same fixture bytes. Do not modify that branch.
- Negative control: temporarily remove the engine loading step and rerun fresh-VM recovery. Matching starts fail with `{:error, :invalid_options_or_recovery}`. Restore the loading step before the final gate.

Durable state, concurrency and unknown outcomes: local small gate and full review. These are finite recovery and byte-comparison scenarios, not a proof.
