# ELZ-305 — A cancel after a delivered result answers unknown_run in runtime/os-isolation

- Dependencies: ELZ-029

## Outcome and scope

Repair flaky test #694 at its cause, without weakening the test. In
`pieces/runtime/os-isolation/test/elzoo/os_process_test.exs`, test "T7
cancelling a queued request yields rejected{cancelled}; the slot flow
continues", the last assertion `assert {:error, :unknown_run} =
OsProcess.cancel(sup, queued2)` sometimes gets `{:error, :already_exited}`.
The cancel arrives after the submitter has received `queued2`'s completed
result but before the Adapter has removed that run's record. It failed
after 175 passing runs in one `--repeat-until-failure 300` launch on a
4-core host, and once in a local aggregate consumer.

The Contract (`piece.json` and README, "cancel/2") is unchanged. It says
`{:error, :already_exited}` is the answer only after a provider exit report
confirms that the leader exited, while the run is still held; every other
finished or foreign ref gets `{:error, :unknown_run}`. A run whose result has
been delivered to its submitter is finished. The Adapter must therefore
answer `unknown_run` to any cancel that it handles after it sent that
result.

Owned paths: `pieces/runtime/os-isolation/lib/**` and
`pieces/runtime/os-isolation/test/**`. If `piece.json` must change, its
`manifest_sha256` row changes in the last commit (AGENTS.md section 3). The
README and the Contract text do not change.

## Required behavior

1. Find where the Adapter sends a run's terminal result and where it removes
   or retires that run's record, and make them one step of the owning
   process, so no cancel can be handled between them. Do not add a sleep, a
   retry, a wait in the test or a second accepted reply.
2. If the Contract cannot be met without a Contract change (for example,
   the result is sent by a process that cannot order itself with the
   record), stop, comment on the issue with the exact path and the reason,
   and do not change the test.
3. The repeated-cancel window of the last 1024 refs settled by
   cancellation (`{:ok, :already_requested}`) and every other reply keep
   their current behavior.

## Acceptance and evidence

1. One kept regression test that forces the window deterministically
   (for example, a cancel handled in the same mailbox turn right after the
   result is sent), passing on the fix and failing on the unfixed code;
   record the failure as a negative control (temporary edit, reverted).
2. T7 unchanged; `mix test pieces/runtime/os-isolation/test/elzoo/os_process_test.exs:366
   --repeat-until-failure 500` passes in one launch on the fix, and the
   same launch on the unfixed code fails or the regression test above
   stands in for it; record both.
3. The Piece suite, the local small gate
   (`mix check --piece "$(git merge-base origin/main HEAD)"`) and
   `git diff --check` pass. The Piece runs OS processes and has concurrency,
   so it keeps the local small gate and gets one full independent review.
4. Exact-head hosted `check-piece` green, the PR marked ready, any automated
   reviewer threads answered and resolved. The coordinator merges.
