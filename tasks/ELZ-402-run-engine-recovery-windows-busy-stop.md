# ELZ-402 — assembly/run-engine: stabilize the busy stop in the Intent recovery windows test

- Dependencies: ELZ-127, ELZ-389, ELZ-396

## Outcome and scope

Defect #967. The case `descriptor and raw-outcome input/result reply-loss
windows recover without a second send or gate call` in
`pieces/assembly/run-engine/test/elzoo/run_engine_test.exs` (line 1638 on
`5bb57c13`) sometimes fails: after `GenServer.stop(engine)`,
`DynamicUnits.stop(directory, c.prefix)` returns `{:error, :busy}` where the
test expects `:ok`. It was reproduced on the unchanged base `24b1b29d` with
`--repeat-until-failure 30` after seven passes. No cause is established yet.

This is a coordinator-owned test-only Piece repair on the one-PR path
(`AGENTS.md` section 1). Publication and implementation share one
`task/ELZ-402` pull request. It changes only files that the run-engine
`piece.json` already lists under its `test/` directory.

## Contract

Unchanged. Diagnose which process still holds the Unit when the stop is
asked and why. If the test races (for example it stops the Units before an
owned process has exited), repair only the test's ordering, with a total wait
on an observable condition, not a longer sleep or a weaker assertion. If the
engine or `DynamicUnits` is at fault, or the repair needs a change outside the
Piece's `test/` files, stop and report it: that needs a published Piece task,
not this path.

## Acceptance

- On the build base, run the named case with
  `mix test <file>:<line> --repeat-until-failure 200`; record the failure, the
  completed iteration count and the interleaving it shows.
- After the repair, the same repeat reaches 200, and the run-engine tests pass
  on disposable PostgreSQL. Keep the case's assertions: no second send, no
  second gate call, and recovery of both reply-loss windows.
- Negative control: temporarily restore the faulty ordering and record the
  reproduced failure in the same repeat; restore the fix before the final
  gate.
- Small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, and `check-piece` passes on the exact head.
