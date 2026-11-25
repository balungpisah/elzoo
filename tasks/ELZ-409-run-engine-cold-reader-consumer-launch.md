# ELZ-409 — assembly/run-engine: launch the fresh-VM reader so it also runs in a copied consumer

- Dependencies: ELZ-408

## Outcome and scope

The push run of `main` on `71e5f2b9` (the merge of ELZ-408, PR #995; run 45702452348, job `check-aggregate`) failed. In the aggregate consumer, all three cases of `pieces/assembly/run-engine/test/elzoo/run_engine_cold_recovery_test.exs` fail at `recover/3`. The fresh-VM reader that the test starts with `mix run --no-compile --no-deps-check --no-start` and `MIX_ENV=test` does not find the consumer's built dependencies: it reports `module Ecto.Repo is not loaded and could not be found` while it compiles `test/support/durable_log_postgres_test_helper.exs`, after warnings that the configured applications `:req_llm` and `:prometheus` are not available. The same cases pass in the Elzoo checkout, so the Piece's own tests and the small gate did not show it; run-engine was ready at the base, so its copied export was not run before the merge (`AGENTS.md` section 5).

After this task the reader starts as a separate fresh BEAM in both the Elzoo checkout and a copied consumer, for example by running `elixir` on the parent VM's code paths instead of resolving a Mix project from the working directory. It must stay a fresh VM: it shares no atom table with the writer and loads no engine dependency before `RunEngine.start_link/1` except through the engine's own loading step, so the test still fails without the ELZ-408 loading step.

This is a coordinator-owned test-only Piece repair on the one-PR path (`AGENTS.md` section 1). Publication and implementation share one `task/ELZ-409` pull request. Release V2, stage `release` (freeze rule 1). It changes only files that the run-engine `piece.json` already lists under its `test/` directory, with no change to `lib/`, `cure/`, `examples/`, `README.md`, `piece.json` or an index row. No other Piece, dependency, pin, workflow or runner label changes.

## Acceptance

- Reproduce the failure first in a copied consumer that holds run-engine (the aggregate consumer of `test/export_test.exs`, or a smaller copied consumer of run-engine's dependency closure if the root helpers provide one), and record the command, its exit code and the error.
- After the repair, the same consumer run passes the three cold-recovery cases, and `mix test pieces/assembly/run-engine/test/elzoo/run_engine_cold_recovery_test.exs --repeat-until-failure 5` passes in the Elzoo checkout.
- Negative control: with the repaired launcher, temporarily remove the engine's loading step in `run_engine.ex`; the cold-recovery cases still fail with `{:error, :invalid_options_or_recovery}`, so the reader is still a fresh VM. Restore it before the final gate; never commit it.
- `mix check --piece "$(git merge-base origin/main HEAD)"`, the copied-consumer run above and `git diff --check` exit 0, and `check-piece` passes on the exact head. The full check on `main` after the merge is green.
