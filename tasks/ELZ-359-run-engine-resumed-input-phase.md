# ELZ-359 — After continue, a resumed paused input that leaves nothing open makes the Run active again

- Phase: repair of the ready Piece `assembly/run-engine` before the first release (defect #843)
- Dependencies: ELZ-127, ELZ-351
- Release: V1B
- Output: none. A bug fix in place of the ready Piece `assembly/run-engine` (ELZ-127) that restores its Contract, with the same Piece ID (`AGENTS.md` section 4).
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/assembly/run-engine/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece, no root test or helper, no other document, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #843. Without the start option `expiry_reports: :owner`, a Run that settles a slot while paused keeps that input and gives it to its pattern after `continue`. If the pattern then opens nothing, and no slot is open, the Run stays `:waiting`, and `workflow/bot-run-lifecycle` decides each later `wake` as `RemainWaiting`: the root is never given a wake again. After an ordinary settlement outside a pause, the same Run would be `:active` and the next `wake` would reach the root. ELZ-351 (#841, merged as 987f31e6) added the switch from `:waiting` to `:active` at a `:resume_input` step, but only for Runs with its option, and left this default behaviour as it was.

This task makes that switch hold for every Run, with and without the option, so that a Run that resumes a retained input and then has nothing open takes new work as after an ordinary settlement. Nothing else changes: no record kind, record shape, ID, start option, configure control, fingerprint, `status/1` key, pattern input, charge or bound.

The engine keeps durable state, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"); the hosted `check-piece` run does not replace the local run (`AGENTS.md` sections 5 and 6).

Defect #854 (an outcome of local work keeps the `pause_deadline` sampled at its dispatch) also touches `run_engine.ex`. It is a separate task and is not repaired here.

## Facts on `main` that this task builds on

Checked at `f40ba178` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex`. Confirm each before you start; if one differs, stop and comment on the issue.

- `settle_protocol/3` switches the lifecycle phase from `:waiting` to `:active` when `active_count/1` is 0 after a settlement (lines 870–873), before the pattern call of the settling input. The dispatch of a slot in phase `:running` or `:waiting` switches `:active` to `:waiting` (lines 380–383).
- `active_count/1` (lines 4658–4659) counts each slot that is not `:settled` or that holds a `pending_input`. `restore_waiting/1` (lines 1037–1041) turns `:active` into `:waiting` while `active_count/1` is above 0. The `:lifecycle` transition (lines 488–499) calls it after `continue` (line 497), so a Run that holds an input retained while paused is `:waiting` after `continue`.
- The wake branch of `protocol_transition/2` gives a `wake` to the root only when the lifecycle decision is `:permit_new_work` and `active_count/1` is 0 (line 734); the branch of `start` and `message` has the same condition (line 771). `workflow/bot-run-lifecycle` (`cure/elzoo/bot_run_lifecycle.cure`, `decide/4`) decides a `Work` event in `Waiting` as `RemainWaiting`.
- The `:resume_input` transition (lines 192–205) removes the slot's `pending_input`, then calls `resume_phase/1`, then `invoke/3` for `slot.callable`, when the Run is neither paused nor terminal, generation is open, no stop is pending and the callable is open. `drain/1` commits the `:resume_input` records before the reply of `control/4`, so the retained input is given before the reply of `continue`.
- `resume_phase/1` (lines 1025–1035) switches `:waiting` to `:active` only when `state.control[:expiry_reports] == :owner`, `active_count/1` is 0 and `state.control.lifecycle.waits` is empty.
- The event-wait reader projects a `:resume_input` record in `project_event_wait_transition/2` (lines 4826–4840): it removes the `pending_input` and calls `resume_phase/1` only `when state.control.expiry_reports == :owner`. `valid_event_wait_close_transition?/3` (line 4851) compares the projected state's close markers, which include `lifecycle.phase` (`event_wait_close_markers/1`, lines 4968–4973), with the folded state. `validate_event_wait_transition/4` runs this check only for `protocol_version` 2 (line 6023 returns `:ok` for version 1). So if the fold switches the phase and the projection does not, `event_waits/3` and `transcript/3` of a v2 Run return `{:error, :history}`.
- The README (lines 583–587) says that the switch holds only with the option, and that without it "a Run that resumes a retained input after `continue` and then opens nothing stays `:waiting`"; lines 596–598 say that the readers project a `:resume_input` with the same phase switch. The `contract` of `piece.json` says "with the option a :resume_input step makes a waiting Run active when nothing is active and no wait is listed".
- The ELZ-351 test `default_off_is_unchanged` (`test/elzoo/run_engine_expiry_report_test.exs`) compares a recorded scenario without the option with a golden SHA-256 and byte length. Its scenario pauses, expires slots while paused and continues, but it retains no settling input while paused, so its history holds no `:resume_input` record.

## The repair

- `resume_phase/1` no longer reads `expiry_reports`: at each `:resume_input` step that gives its input (a held expiry report, or an input retained while paused), after the `pending_input` is removed and before the pattern call, a `:waiting` Run becomes `:active` when `active_count/1` is 0 and `lifecycle.waits` is empty. Both remaining conditions stay.
- The event-wait projection of a `:resume_input` (`project_event_wait_transition/2`) applies the same step for every Run, so that `event_waits/3` and `transcript/3` reach the state of the fold.
- A `:resume_input` step that gives nothing (its conditions in the transition do not hold) changes nothing, as today.
- The README (the two sentences above, and the sentence on the root's input rule if it needs it), the `contract` of `piece.json`, its `grounding` (the new test names) and the code comments of `resume_phase/1` and of the projection say that the switch holds for every Run; the `note` and `manifest_sha256` of the index row follow `piece.json`.

## Acceptance

Tests use the Piece's disposable PostgreSQL (`ELZOO_TEST_DATABASE_URL`) and the test helper's `fixture/1`, `start/2`, `view/1`, `verified/1` and `TestPattern.waiting/2` (with `:run_engine_observer` registered, so each pattern input is sent to the test process). The v1 cases go in `test/elzoo/run_engine_test.exs` and the v2 case in `test/elzoo/run_engine_v2_test.exs`, as new tests; no existing test and no existing helper function changes.

1. **`resumed_input_reopens_the_root`** (protocol v1, no option): the root asks one `ask_person`. The Run pauses; a `person_answer` settles the slot and is retained; `continue`. The root's pattern is given the answer once and returns `:none`. At the reply of `continue`, `view/1` shows phase `:active` with no slot active. A later `wake` is given to the root (exactly one pattern input of kind `wake`), and the request that the root returns for it is admitted. One restart after `continue` gives the same phase and calls no pattern; it is the restart of `restart/3` in `test/elzoo/run_engine_test.exs`, which stops the engine and its Unit (`DynamicUnits.stop/2`) and sets the host to recover, so the phase comes from the Unit's history in PostgreSQL and not from a live Unit. On `main` this case fails: the phase is `:waiting` and the `wake` is not given to the root.
2. **`resumed_input_with_open_work_stays_waiting`** (protocol v1, no option): as case 1, but the root's first request also asks an action that stays open after `continue`:
   - a `local_work` action whose work is still running: after `continue` the phase is `:waiting`, and a `wake` is not given to the root;
   - a second `ask_person` that is still waiting: the same.
3. **`native_v2_resumed_input`** (protocol v2, no option, with a `result_reader`): as case 1 with v2 inputs. After `continue`, `event_waits/3` and `transcript/3` read the Run with no error, the phase is `:active`, and a later v2 `wake` is given to the root.
4. **The option is unchanged.** Every existing test of the Piece passes unchanged, the tests of `test/elzoo/run_engine_expiry_report_test.exs` included. `default_off_is_unchanged` passes with its committed golden values. Expected: its trace does not change, because its scenario writes no `:resume_input` record, and this repair changes only the `:resume_input` step. The pull request says whether the trace changed and why. If it changed, stop and comment on the issue before changing the golden values.

Negative controls, each a temporary edit of `lib/` that is reverted and never committed; record each failure in the pull request:

- the option condition kept in `resume_phase/1` and in the projection (the code of `main`): case 1 fails (phase `:waiting`, the `wake` is not given to the root), and so does case 3;
- the `active_count/1` condition removed from `resume_phase/1`: case 2's `local_work` item fails (the phase is `:active` while the work runs);
- the fold switched for every Run while the projection keeps the option condition: case 3 fails (`event_waits/3` returns `{:error, :history}`).

## Gate, review and build

Run `mix test pieces/assembly/run-engine/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which runs the tests of the ready Pieces that depend on the engine (`delivery/room`, `runtime/recipe-test`, `workflow/eval`) and the per-ID consumers, and `git diff --check`. The root acceptances that start the engine run in the full check on `main` after the merge (`AGENTS.md` section 7). The full independent review of the coordinator guide ("Reviewer by risk") finds the code and a test for each rule of this text. Then the exact-head hosted `check-piece` and the merge queue.

`docs/plans/bot-platform-wave8.md` and `docs/plans/bot-platform-wave9.md` name #843 as open at the time they were written; they stay unchanged.

## Limits to state

- Only the `:resume_input` step changes. A resumed input whose callable is a child, while the child's parent slot (or any other slot) is still active, leaves the Run `:waiting` until that slot settles, as after an ordinary settlement.
- The engine has no timer: a Run that becomes `:active` takes new work only at the host's next `wake`, `start` or `message`.
- No compatibility claim is made for a Unit history written by an engine build before this repair (Elzoo is not released): such a history folds with the repaired step.
- #854 is not repaired here.
- Finite listed scenarios on disposable PostgreSQL, not a proof.
