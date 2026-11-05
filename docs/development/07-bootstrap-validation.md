# Bootstrap validation

This is a one-time acceptance record, not an extra task lifecycle.

## Environment and reproducibility

The coordinator independently cloned `balungpisah/elzoo` at
`3965fb2648e01d4a4c355e42438386d2de228545` into a new temporary directory.
The clone began with no `deps/` or `_build/`. No compiler or application
artifacts were copied from Zoo or another checkout. Normal machine-wide Hex
download caches were available.

- Elixir: 1.20.4.
- Erlang/OTP: 29.1.2, read from the installed `OTP_VERSION` file.
- Cure: `a004c335cc4e9f2203ba6f51fc31e8540b66378d`; dependency checkout SHA
  matched and its tracked source remained clean after setup.
- Jason: 1.4.5, locked in `mix.lock`.
- Scheduler limits: `ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1"`.

`mix setup` succeeded in 363 seconds on the bootstrap machine. The first
`mix check` succeeded in 229 seconds because that initial version built dev
and test dependencies separately. Both commands now prefer the test
environment to share the same compiler build. Warm complete checks take
approximately four seconds here; timings are observations, not a performance
contract. After the shared-test-environment change, the coordinator repeated
`mix setup` and `mix check` in that fresh clone and verified that only the test
BEAM changed; the dev BEAM timestamp stayed unchanged. No build artifacts were
copied for that recheck. The first dependency build still compiles Cure's standard library
and escript using its upstream build alias.

## Checks actually performed

| Check | Observed result |
| --- | --- |
| Independent `mix check` in the working repository | Exit 0, eight tests passed, `ELZOO CHECK PASSED` |
| Fresh-clone `mix setup`, then `mix check` | Both exit 0; eight tests passed |
| Selected Cure proofs and audit | Four general proof functions compile; selected pure audit has no holes/hidden axioms |
| Independent model comparison | Empty trace plus 20 seeded traces of 30 messages; fused and OTP outputs/state match the set/sum reference |
| Deliberately failing ExUnit fixture through actual `mix check` | Exit 2; success marker absent; fixture then removed |
| `mix check test/elzoo/runtime_test.exs` | Exit 1; targeting rejected and success marker absent |
| Temporary `BuildProbe.Temporary` Cure source | Real BEAM emitted, then removed after deleting the source and recompiling |
| Fresh-clone working tree after probes | `git status --porcelain` empty |
| Production release evaluation | All four `Cure.Elzoo.*` modules listed in the application, loaded, and executed a duplicate-input example yielding `[{:some, 7}, :none]` |
| Disposable two-clone claim race | First push accepted; competing claim rejected; recorded handoff accepted as fast-forward |
| Stale archive/delete race | Exact-tip deletion refused after a concurrent branch advance; newer work retained |
| Task DAG and document links | All 12 bodies resolve; DAG acyclic; table/direct edges/body dependencies agree; local links resolve |

The runtime leaf implemented and checked its own work; the coordinator
reviewed the code, fixed integration findings, reran the complete check,
performed the fresh-clone/failure/claim probes and evaluated the built release.
This is bootstrap acceptance on the initial main branch, not a claim that
future tasks may skip independent review.

## Linux CI

The first Linux run passed on Ubuntu 24.04 with the pinned Elixir/OTP versions:
[Check run 42013712025](https://github.com/balungpisah/elzoo/actions/runs/42013712025).
It used GitHub-hosted infrastructure and freshly installed dependencies, with
no access to the local Zoo checkout. Subsequent runs cache dependencies/builds;
Mix still compiles the checked-out project and executes the full tests.

## Limits and lessons

- This is a volatile sample with exact-key, unbounded deduplication. Named
  versioned ports/wiring, bounded windows, resilience, durable storage,
  network effects and products remain in the ELZ backlog.
- Fused and synchronous OTP traces agree in the named scenarios. That does
  not prove arbitrary interleaving, crash atomicity or distributed behavior.
- Jason's implementation and Cure/OTP remain upstream trust boundaries.
- Cure's standalone `compile_file/2` API performs elaboration, kernel checks
  and BEAM generation. The bulk API with project-only roots rejected the
  bootstrap with `missing_module` for `Std.Option`; this harness uses the
  supported standalone API and the upstream dependency graph for ordering.
- Project-only source roots avoid the import slowdown described in
  [Cure notes](../cure-notes.md). A whole-stdlib preload is unnecessary.
- Mix can return from its test task before its exit-status hook runs. The
  success marker is emitted by an exit hook only when the final status is 0.
