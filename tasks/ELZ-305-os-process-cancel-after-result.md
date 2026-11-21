# ELZ-305 — A cancel after a delivered result answers unknown_run in runtime/os-isolation

- Dependencies: ELZ-029

## Outcome and scope

Repair flaky test #694 at its cause, without weakening the test. In
`pieces/runtime/os-isolation/test/elzoo/os_process_test.exs`, test "T7
cancelling a queued request yields rejected{cancelled}; the slot flow
continues", the last assertion `assert {:error, :unknown_run} =
OsProcess.cancel(sup, queued2)` sometimes gets `{:error, :already_exited}`.
It failed after 175 passing runs in one `--repeat-until-failure 300` launch
on a 4-core host, and once in a local aggregate consumer. T17's last
assertion (`os_process_test.exs`, around line 705) has the same race.

The cause, from the code at ELZ-029: the Owner sends the result to the
submitter (`owner.ex`, `send(state.submitter, …)`) and only then rewrites
its registry row as finished; the Adapter keeps the run in `state.running`
until it handles the Owner's exit (`owner_down`). A submitter that receives
the result and cancels at once can reach the Adapter first. The Adapter then
answers from the run's live state.

The Contract is unchanged. README "cancel/2": `{:error, :already_exited}`
"only once a provider exit report confirms that the leader has exited (…
the result then reports what remains …)", and "every other finished or
foreign ref gets `{:error, :unknown_run}`". A run whose result has been sent
to its submitter is finished. So a cancel that the Adapter handles after the
result was sent answers `{:error, :unknown_run}`, with one exception the
Contract names: a ref among the last 1024 queued runs settled by
cancellation answers `{:ok, :already_requested}`. In this task the window
starts when the run's registry row is retired as finished, and the result
is sent immediately after that step.

Owned paths: `pieces/runtime/os-isolation/lib/**` and
`pieces/runtime/os-isolation/test/**`. Conditionally, if a new test file or
new grounding must be listed: `pieces/runtime/os-isolation/piece.json`,
then, in the last commit, its `docs/plans/release-plan.json` entry
(`manifest_sha256`) and the generated `LEDGER.md` and `docs/plans/views.md`
(AGENTS.md section 3). The README and the Contract text do not change.

## Required behavior

1. From the moment a run's row is retired as finished (immediately
   before its result is sent), every cancel of that ref that the Adapter
   handles answers `{:error, :unknown_run}`, except the 1024-ref
   cancellation exception above. Replies that occur in that window today
   include, and each becomes `unknown_run`:
   - `{:error, :already_exited}` after a normal completion;
   - `{:ok, :already_requested}` for a run that already had a cancel
     requested (T17);
   - `{:error, :exit_unconfirmed}` for a run whose provider closed or did
     not report an exit;
   - `{:ok, :requested}` or `{:error, :exit_unconfirmed}` for a run whose
     Owner ended it `rejected{spawn_failed}` before the provider returned
     an OS pid. (A run past its deadline at dispatch gets `expired` without
     an Owner or a running entry, so it is outside this race.)
2. Order the steps so the invariant holds without a sleep, retry, wait in
   the test or second accepted reply. One way that keeps the current
   process design: the Owner retires its registry row before it sends the
   result, and the Adapter's cancel answers `unknown_run` for a retired row
   before it looks at `state.running` or `cancel_requested`. Moving result
   delivery into the Adapter is not required; it would change the README's
   statement that a running Owner replies to the submitter itself, which
   this task keeps.
3. A run gives its submitter at most one result, whenever its Owner is
   killed (README: "does not notify twice"; the Adapter's observer already
   follows this rule). An Owner killed after it sent the result gives
   exactly that result and no second one from the observer path. An Owner
   killed with `:kill` between retiring its row and sending gives no
   result; the caller's `run/3` wait then ends with `{:error, {:no_result,
   ref}}`. State this as a limit in the PR body. The README does not
   change. Today's order can give two results in the same window; this
   task removes that.
4. Every reply before the row is retired keeps its current behavior.
5. Stop and comment on the issue, with the path and the reason, only if
   the invariant cannot be met with the Contract as written after trying
   the ordering above. Do not change the test to pass.

## Acceptance and evidence

1. One kept regression test that forces the window deterministically: the
   cancel must reach the Adapter before the Owner's exit does, for example
   through a hook in `config.test_hooks` that blocks the Owner right after
   the send. It passes on the fix and fails on the unfixed code. Record that
   failure as a negative control (temporary edit, reverted).
2. Tests for behavior 3, each forced through a hook: the Owner killed
   between retiring its row and the send gives no result and no second
   result; the Owner killed right after the send gives exactly one
   result.
3. T7 and T17 unchanged.
   `mix test pieces/runtime/os-isolation/test/elzoo/os_process_test.exs:366
   --repeat-until-failure 500` passes in one launch on the fix. Record the
   same launch on the unfixed code; if it happens not to fail, the
   regression test above is the negative evidence.
4. The Piece suite, the local small gate
   (`mix check --piece "$(git merge-base origin/main HEAD)"`) and
   `git diff --check` pass. The Piece runs OS processes and has
   concurrency, so it keeps the local small gate and gets one full
   independent review.
5. Exact-head hosted `check-piece` green, the PR marked ready, and any
   automated reviewer threads answered and resolved. The coordinator merges.
