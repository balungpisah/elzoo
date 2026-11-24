# ELZ-360 — A local-work outcome takes the host's pause deadline when it is committed, not when the work was dispatched

- Phase: repair of the ready Piece `assembly/run-engine` before the first release (defect #854)
- Dependencies: ELZ-127, ELZ-351, ELZ-359
- Release: V1B
- Output: none. A bug fix in place of the ready Piece `assembly/run-engine` (ELZ-127) that restores its Contract, with the same Piece ID (`AGENTS.md` section 4).
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/assembly/run-engine/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece, no root test or helper, no other document, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #854. This publication does not resolve #854; the build pull request does.

Under `budget_rule: :pause`, a local-work outcome is committed with the `pause_deadline` that the host's `context` callback gave when the work was dispatched. When the work finishes after that deadline, and the step of its outcome must enter the pause, the lifecycle refuses the passed deadline and the fold step raises: the engine halts, and the next input returns `{:error, :durable_unit_transition_failed}`. Two triggers were reproduced on `main` without any option: the root's request for the outcome is the Run's first excess of the request cap, and the outcome's actual exhausts the Budget. With a deadline that is still in the future at dispatch, the same Runs pause and go on.

The README states the rule this breaks (the `start_link(opts)` facts, the `budget_rule` item, line 44–45): "Pause exhaustion requires a verified future `pause_deadline` before evaluating the driving input." A host input meets it through `pause_operand/3`. Every other record that the engine makes itself samples the host's `context` callback when it is committed. Only the local-work outcome samples it at dispatch.

This task makes the local-work outcome follow the same rule as the other engine-made records: its `pause_deadline` is the one that the host's `context` callback gives when the outcome is committed, in the v1 and the v2 path. It also states the host Need explicitly. Nothing else changes: no record kind, record ID, option, configure control, fingerprint, `status/1` key, pattern input, charge, bound or lifecycle rule. The ELZ-351 guard in `expire_and_report/3` stays as it is. No fallback is added to the fold for a callback that itself gives a passed deadline; that stays outside the Need.

The engine keeps durable state and settles unknown outcomes, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"). The hosted `check-piece` run does not replace the local run (`AGENTS.md` sections 5 and 6).

## Facts on `main` that this task builds on

Checked at `9580f2b1` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex`. Confirm each before you start; if one differs, stop and comment on the issue.

- `dispatch/3` for `local_work` (line 3277) samples `context = s.opts.context.()` (line 3286) before it starts the work. The AsyncWork wrap builds the outcome record when the work finishes, with `at_ms` from `clock.()` at that time and `context: Map.take(context, [:pause_deadline])` from the dispatch sample (line 3318), and delivers `{:durable_unit_input, id, record}` under the ID `stable_id("local:", {1, run_id, key})`. `context` has no other use in that function.
- The v1 handler `handle_info({:durable_unit_input, id, %{version: 1, kind: :protocol} = record}, s)` (line 1863) runs `checked_ingress/3` with `Map.merge(record.context, record.correlation)` and commits the record. The v2 handler (line 1830) commits an identical record that the Unit already holds, and otherwise passes a local-work record (`local_work_protocol_record?/2`, line 1841) to `accept_local_work_input/3` (line 1920), which runs the same `checked_ingress/3` and commits it. Neither path calls `pause_operand/3`.
- `do_commit/3` resolves an `input_id_conflict` as `:unchanged` when the committed record has the same `kind`, `request` and `occurrence` (all absent or `:protocol` for a local-work outcome). So a second delivery of an outcome whose context differs commits nothing and halts nothing.
- The other engine-made records sample the callback when they are built for commit: `internal_outcome/6` (line 3701; `context: Map.take(s.opts.context.(), [:pause_deadline])` at line 3725, also used by `recover_local/1` at line 2903) and the `:nested` record (line 3372). The resource-cursor records check `pause_operand/3` (line 3859).
- `pause_operand/3` (line 4649) admits a context under `budget_rule: :pause` only when `pause_deadline` is an integer after the input's `at_ms`.
- The first excess of the request cap closes generation with `close_over_cap_generation(state, record.context, record.input["at_ms"])` (line 1294). `workflow/bot-run-lifecycle`'s `EnterPause` (`project/6`) takes `event[:pause_deadline] || context[:pause_deadline]` and returns `{:error, :invalid_shape}` unless that deadline is after the event's time. The engine matches `{:ok, ...}` on that result, so the fold step raises.
- `expire_and_report/3` (line 1501) holds expiry reports under `budget_rule: :pause` only when `context.pause_deadline > at` (line 1506). Its comment, README lines 561–564 and 1227–1228, and the `piece.json` `contract` explain that guard by a local-work outcome "dispatched before that deadline". The ELZ-351 test `under budget_rule :pause an expiry whose input's pause deadline has passed holds no report` (`test/elzoo/run_engine_expiry_report_test.exs`, line 398) keeps the test helper's callback at 50,000 while the clock reaches 51,000, and its comment (line 399) names the deadline "of its dispatch".
- The test helper's `context` callback reads an Agent (`c.context`) that starts with `pause_deadline: 50_000` (`test/support/run_engine_test_helper.exs`, about line 553), so a test can change the callback's deadline between dispatch and outcome with `Agent.update/2`.
- The ELZ-351 golden trace (`default_off_is_unchanged`) runs no local work.

## The repair

- The v1 and v2 handlers of a delivered local-work outcome replace the record's `context` with `Map.take(s.opts.context.(), [:pause_deadline])`, sampled when they handle the delivery, before `checked_ingress/3` and the commit. The record that is committed carries that deadline. `dispatch/3` keeps no context sample for the outcome. Where the sample is taken inside the delivery handling is the worker's choice; the deadline must never be the one from dispatch.
- A delivery of an outcome that the Unit already holds stays as today: no second commit, no conflict and no halt.
- The README states the host Need in the `start_link(opts)` facts, at the `context` item: under `budget_rule: :pause`, the `context` callback gives a `pause_deadline` after the clock each time the engine samples it (for a local-work outcome, an engine refusal or loss, and a nested start). A callback that gives a passed deadline is outside the Need: a first excess or a Budget exhaustion in the step of such a record still halts the engine. That is also a stated Limit.
- The texts that explain the ELZ-351 guard by the dispatch time say instead that the guard covers an input whose `pause_deadline` is not after its time, such as an engine-made record whose sample from the callback has passed: the comment of `expire_and_report/3`, README lines 561–564 and 1227–1228, the `piece.json` `contract`, and the comment at line 399 of `run_engine_expiry_report_test.exs` (comment only; the test code does not change). The guard's code stays as it is.
- `piece.json` (`contract`, `limits`, `grounding`) and the README follow; the `note` and `manifest_sha256` of the index row follow `piece.json`.

## Acceptance

Tests use the Piece's disposable PostgreSQL (`ELZOO_TEST_DATABASE_URL`) and the test helper's `fixture/1`, `start/2`, `view/1`, `verified/1`, `TestPattern.waiting/2` and the blocked local work (`TestPattern.blocked/3` through the `local_work` binding), with `:run_engine_observer` registered so each pattern input reaches the test process. In each case, local work is dispatched while the callback gives `pause_deadline` 30,000. The callback is then set to 50,000, and the work ends at 35,000 (in cases 1–3 it completes, before its own deadline of 40,000). The v1 cases go in `test/elzoo/run_engine_test.exs`, the v2 case in `test/elzoo/run_engine_v2_test.exs` and the expiry-report case in `test/elzoo/run_engine_expiry_report_test.exs`, as new tests. No existing test or helper function changes; the one comment above may change.

1. **`local_outcome_pauses_on_the_current_deadline`** (v1, no option, `request_cap: 1`, `budget_rule: :pause`): the root asks the local work, and on its outcome asks a second request, the first excess. The Run is `:paused` with `pause_deadline` 50,000, the committed outcome record's `context` is `%{pause_deadline: 50_000}`, and the next input applies with no error. A restart with `restart/3` gives the same phase and pause deadline and calls no pattern. On `main` this case fails: the next input returns `{:error, :durable_unit_transition_failed}`.
2. **`local_outcome_exhaustion_pauses_on_the_current_deadline`** (v1, no option, `budget_rule: :pause`, Budget cap 1): the local work's actual exhausts the Budget in its outcome's own step, and the root returns `:none` for the outcome. The Run is `:paused` with `pause_deadline` 50,000, and the next input applies. On `main` it fails as case 1.
3. **`native_v2_local_outcome_pause_deadline`** (protocol v2, with a result reader, `request_cap: 1`, `budget_rule: :pause`): as case 1 through the v2 path. The Run is `:paused` with 50,000, `event_waits/3` and `transcript/3` read the Run with no error, and the next v2 input applies.
4. **`report_uses_the_current_deadline`** (`expiry_reports: :owner`, `budget_rule: :pause`): the local work's own deadline is 33,000, and it is lost at 35,000, after that deadline. Its outcome's expiry pass settles the slot `expired`, and because the outcome now carries 50,000, after 35,000, the report is held and given to the root (one `:resume_input` record). On `main` no report is held, because the outcome carries 30,000. The existing ELZ-351 test at line 398, where the callback still gives 50,000 at 51,000, passes unchanged: no report is held.
5. **The rest is unchanged.** Every existing test of the Piece passes unchanged, `default_off_is_unchanged` with its committed golden values. Expected: its trace does not change, because it runs no local work. The pull request says whether it changed and why. If it changed, stop and comment on the issue before changing the golden values.

Negative controls, each a temporary edit of `lib/` that is reverted and never committed; record each failure in the pull request:

- the dispatch-time sample kept in both paths (the code of `main`): cases 1–3 fail with `{:error, :durable_unit_transition_failed}`, and case 4 holds no report;
- the commit-time sample in the v1 handler only, with the v2 path keeping the delivered context: case 3 fails;
- the ELZ-351 guard condition removed from `expire_and_report/3` (`budget_rule == :finish or pause_deadline > at`): the existing ELZ-351 test at line 398 fails, which shows that the guard is still needed after this repair.

## Gate, review and build

Run `mix test pieces/assembly/run-engine/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"`, which runs the tests of the ready Pieces that depend on the engine (`delivery/room`, `runtime/recipe-test`, `workflow/eval`) and the per-ID consumers, and `git diff --check`. Keep no untracked symlink in the worktree, such as a linked `deps`: the small gate refuses a symlink in the change. The root acceptances that start the engine run in the full check on `main` after the merge (`AGENTS.md` section 7). The full independent review of the coordinator guide ("Reviewer by risk") finds the code and a test for each rule of this text. Then the exact-head hosted `check-piece` and the merge queue.

`docs/plans/bot-platform-wave8.md` and `docs/plans/bot-platform-wave9.md` stay unchanged.

## Limits to state

- The host Need above: a `context` callback that gives a passed `pause_deadline` under `:pause` is outside it, and a pause that the step of such a record needs still halts the engine. No fold fallback is added for it.
- A Unit history that already holds a local-work outcome with a passed dispatch-time deadline folds as before; such a history halted when it was written (Elzoo is not released).
- The deadline is the callback's value when the delivery is handled, not at the instant the work finished; the two differ only by the time the delivery waits in the engine's mailbox.
- Finite listed scenarios on disposable PostgreSQL, not a proof.
