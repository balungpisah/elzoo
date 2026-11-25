# ELZ-406 — assembly/run-engine: pin recovery from the frozen DurableUnit rows

- Dependencies: ELZ-127, ELZ-387, ELZ-404
- Release: V2
- Stage: `release`
- Output: no new Piece ID.
- New external dependency: none.
- Change class: Piece-only implementation.
- Owned paths: fixture files and fixture test under `pieces/assembly/run-engine/test/`, the file list in its `piece.json`, only its manifest hash and note in `docs/plans/release-plan.json`, and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

Unchanged. This is X2 in `docs/plans/first-release.md`. First compare the `lib/` and `cure/` trees of `assembly/run-engine` and its `runtime/durable-unit` record writer at the build base with `0a76dd21` (F's merge); stop and report to the coordinator if they differ. They match at the publication base `00c842f9`. Use the frozen code at the build base; do not change any writer, reader or runtime Contract.

## Acceptance

- Capture committed DurableUnit Store rows from real Runs written by the frozen engine, not hand-built engine records. Cover `protocol_version: 1` (also the default), `protocol_version: 2` with a `wait_event`, and Runs exercising `expiry_reports: :owner` and `messages: :while_active` (both valid on v1 and v2). Include a completed, a paused and an open Run. Keep the original row payload bytes and order and pin each fixture file's SHA-256.
- On disposable PostgreSQL preload the fixture rows in a fresh Store and recover with `RunEngine.start_link/1` and matching options. Supply matching authoritative Run-owner state and the configured retained reader; a completed result also needs the canonical completion-evidence row it references. Compare `status/1`, scoped `transcript/3` and scoped `result/3` with the recorded replies, including `{:pending, :not_completed}` for nonterminal Runs and the retained result for the completed Run. Do not generate replacement engine rows before recovery. Pass one more valid `input/4` to the open Run and assert that it progresses. On the same rows and Run identity, adding or removing a recorded start option (`expiry_reports: :owner` or `messages: :while_active`) must make `start_link/1` return `{:error, :incompatible_recovery}`.
- Negative control: temporarily rename a control key used in recovery without rewriting the fixtures, show recovery of the fixture fails, and restore before the passing gate. Add fixtures to `piece.json`'s `files`, update the index hash and ensure its note still equals the unchanged `contract`. Later additions do not rewrite pinned files.

Durable state: run the Piece tests, local small gate and `git diff --check`; require exact-head hosted `check-piece` and full independent review under “Reviewer by risk”. Listed scenarios, not a proof.
