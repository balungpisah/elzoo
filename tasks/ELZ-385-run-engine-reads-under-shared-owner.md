# ELZ-385 — assembly/run-engine: the read-only result, wait and transcript reads recheck the Run's own owner facts, so another Run of a shared owner does not fail them

- Phase: repair of the ready Piece `assembly/run-engine` before the first release (defect #931)
- Dependencies: ELZ-127, ELZ-265, ELZ-298
- Release: V1B
- Output: none. A change in place of the ready Piece `assembly/run-engine` (ELZ-127; event waits ELZ-265, transcript ELZ-298) before the first release, with the same Piece ID (`AGENTS.md` section 4): a read that failed under a shared Run owner now succeeds; every other result is unchanged.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/assembly/run-engine/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece (`workflow/run-approval-release` and `integration/mcp-server` included), no root test or helper (the Wave 9 acceptance harness included), no `mix.exs`, `mix.lock` or CI.

## Defect

Reported in #931. This publication does not settle #931; the build pull request does.

On `main` (checked at `c6fe7a8f`), `Elzoo.RunEngine.result/3` of a completed Run reads the Run owner with `Run.status/2` (`result_owner/1`), reads the history (`ResultReader.read/10`), reads the owner again and requires `owner_snapshot(owner) == owner_snapshot(current)` (`completed_result/3` in `lib/elzoo/run_engine.ex`); a difference is `{:error, :completion_mismatch}`. `event_waits/3` and `transcript/3` make the same recheck in `read_retained/4`, where a difference is `{:error, :unavailable}`. `owner_snapshot/1` takes `:id`, `:outcome`, `:operation_id`, `:current_attempt`, `:revision`, `:completion_revision` and `:evidence_ref`.

`:revision` is not a fact of the one Run: `Elzoo.RunApprovalRelease.status/2` reports it as the revision of the owner's whole stream (`view/2` in `run_approval_release.ex`: `Map.put(:revision, s.held.live.revision)`). A Run owner holds several Runs: a nested child Run is a Run of its parent's owner (`attach_child`), and ELZ-349 and ELZ-379 host one owner per tenant. So any command that another Run of the same owner commits between the two reads (a `create`, a `begin_attempt`, a `complete`) fails the read of this Run, although nothing of this Run changed. ELZ-379 observed it once: `result/3` of a completed bot Run was `{:error, :completion_mismatch}` while another Run of the tenant's owner completed. `integration/mcp-server` maps a `result` Need answer `{:error, _}` to the tool error with `"state": "unknown"` (its README, step 4 table), so an MCP call whose Run completed can be answered `unknown`.

A shared owner is inside the Contract (nested callables need it), and every owner fact that the readers use is a fact of the Run: `ResultReader` reads `owner.id`, `owner.operation_id`, `owner.current_attempt`, `owner.outcome` and `owner.evidence_ref`, and the owner checks (`valid_completion_owner?/3`, `valid_event_wait_owner?/2`) also read `revision` only to check its form. The stream revision of the owner adds no fact to the recheck and only turns other Runs' commands into failures. The Unit and evidence stream heads keep their own rechecks.

## The change

- The owner recheck of `result/3`, `event_waits/3` and `transcript/3` compares the Run's own facts, `:id`, `:outcome`, `:operation_id`, `:current_attempt`, `:completion_revision` and `:evidence_ref`, and no longer the owner's stream `:revision`. The form checks of the owner (`revision` a positive integer, `completion_revision <= revision`) stay.
- Nothing else changes: every other check, bound, error and result, the stream-head rechecks, and the engine's own commands to the owner, which still carry `expected_revision` (the host Need that commands to one shared owner run one at a time, ELZ-349, is unchanged).
- README: the three places that state the recheck say what it compares (the paragraph "The reader folds complete retained Unit history…" in the event-waits section, the transcript section's list of rechecks, and "rechecks owner revision and stream heads before returning" in the result section) and that another Run of the same owner does not fail it. `piece.json` (`contract`, `grounding`) follows; the `note` and `manifest_sha256` of the index row follow `piece.json`.

## Acceptance

New tests through the public reads, with a Store read hook that holds the reader between its two owner reads, as `Elzoo.RunEngine.ReaderProofStore.read_hook/2` does in `test/elzoo/run_engine_v2_reader_proof_test.exs` (the test "owner failures, mismatches, and changes during the retained fold are unavailable", whose last case commits a `begin_attempt` while `event_waits/3` is held):

1. **Result under a shared owner.** A completed Run `run` and, while `result/3` of `run` is held, a `create` of another Run on the same owner with the owner's current `expected_revision`, which commits: `result/3` is `{:ok, result}` equal to the result read with no other command. On `main` this case is `{:error, :completion_mismatch}`.
2. **Waits and transcript under a shared owner.** The same interleaving for `event_waits/3` of a waiting Run and `transcript/3`: `{:ok, _}`, equal to the read with no other command. On `main` both are `{:error, :unavailable}`.
3. **The Run's own facts still count.** The existing test in which a `begin_attempt` of the same Run commits while `event_waits/3` is held still gives `{:error, :unavailable}`, and the same interleaving for `transcript/3` gives `{:error, :unavailable}`.
4. **The rest is unchanged.** Every existing test of the Piece passes unchanged (the `completion_mismatch` tests of damaged history and evidence included), and the tests of the ready Pieces that depend on `assembly/run-engine`, which the small gate runs.

Negative control, a temporary edit of `lib/` that is reverted and never committed: put `:revision` back into the compared facts, and cases 1 and 2 fail. Record the failure in the pull request.

## Gate, review and build

Run `mix test pieces/assembly/run-engine/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which also runs the tests of every ready Piece that depends on `assembly/run-engine`, and `git diff --check`. The Piece keeps durable state and reads across concurrent commands, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk", `AGENTS.md` section 6). The hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- The reads still answer `completion_mismatch`, `unavailable` or `history` when this Run's own owner facts or a stream head change during the read; a host that reads a Run while it moves can still see them and reads again.
- The engine's commands to a shared owner still need the host to run them one at a time (ELZ-349); this task changes no write.
- Listed scenarios, not a proof.
