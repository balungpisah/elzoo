# ELZ-033 validation record

The documentation worker ran these checks in the supplied isolated workspace
`/Users/laptopdp/.t3/worktrees/elzoo/t3-772a5980`, based on main
`404d159a122d18a22554c5688aa79199e4d5c124`. The implementation is documentation,
planning data, generated planning views and their checker; runtime source and
ready metadata are unchanged. Final review, symbolic PR checks, merge acceptance
and task cleanup remain with the dedicated roadmap coordinator.

## Actual commands and results

All Mix processes used `ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`.
`mix.exs` selects the test environment for the public setup/check aliases.

| Command | Actual result |
| --- | --- |
| `graft ask "ELZ-033 product-led roadmap adoption documentation planning and preflights" --source` | Exit 127: `zsh:1: command not found: graft`; used `rg` fallback. |
| `mix setup` | Exit 0 from this fresh checkout. Fetched/build dependencies locally; no Cure cache copied from another checkout. |
| `mix check` with dedicated `ELZOO_TEST_DATABASE_URL` | Exit 0; `Result: 27 passed` for Ash experiment; `Result: 300 passed` for root suite; `ELZOO CHECK PASSED`. Root suite reports 301.8 seconds. Includes real Cure compilation, selected laws and negative controls, runtime/provider and independent source-copy consumers. |
| `python3 scripts/check-roadmap.py --write` | Exit 0; generated only `docs/plans/views.md` and `dependencies.mmd`. |
| `python3 scripts/check-roadmap.py --live --self-test` | Exit 0; 97 baseline/current catalogue IDs, 2 separate candidates, 76 jobs, 12 products, acyclic/release-ordered references, generated views agree, 124 local link targets checked, all live published Contract hashes/dependencies match; eight invalid-plan controls rejected. |
| `python3 scripts/check-claims.py` | Exit 0: `No tracked claim metadata`. |
| `python3 scripts/check-ci-runners.py` | Exit 0: `All workflow runner selectors target symbolic; no hosted fallback`. |
| `git diff --check` | Exit 0, no output. |
| `git diff --exit-code 404d159a122d18a22554c5688aa79199e4d5c124 -- pieces lib test registry LEDGER.md mix.exs mix.lock spikes .github .tool-versions .gitignore .ignore` | Exit 0, no output: runtime, metadata, ledger, pins, lockfiles, workflow and unrelated root ignore files preserved. |

The live Contract check also verifies that the new task file exactly equals
issue #55's body. All earlier task files are unchanged. The eight in-memory
negative controls are duplicate entry, missing primary owner, dependency cycle,
later-release prerequisite, candidate counted in baseline, rewritten baseline
status, changed published dependency and unknown product reference. These are
finite validator tests, not proofs of arbitrary plan meaning. Local link checks
validate file targets, not remote URL availability or Markdown anchors.

`elixir --version` reports 1.20.4; installed OTP `OTP_VERSION` reports 29.1.2;
`git -C deps/cure rev-parse HEAD` reports exactly
`a004c335cc4e9f2203ba6f51fc31e8540b66378d`. No moving Cure ref or modified lockfile
was used. Upstream dependency compilation emitted warnings; the full command
nevertheless exited 0 under the existing checker.

A task-specific cluster was initialized with `initdb` under an independently
created temporary directory, on loopback port 65012, role/database `elzoo_033`.
The Mix child process received
`ELZOO_TEST_DATABASE_URL=ecto://elzoo_033@127.0.0.1:65012/elzoo_033`.
It never used the already installed personal PostgreSQL service. The named test
observation was PostgreSQL 17.11 (Homebrew), `fsync=on`,
`synchronous_commit=on`; this is a local observation, not a durability proof or
new server pin. The dedicated cluster was stopped after checking. Symbolic
services and their queues were not touched.

## Output locations and evidence limits

Full local outputs are retained at:

```text
/Users/laptopdp/.codex/artifacts/elzoo-033-validation-2026-11-07-t3-772a5980/
  setup.log
  check.log
  check-exit.txt
  roadmap.log
  guards.log
  toolchain.log
  postgres.log
```

These outputs are inspection artifacts, not a checkout/runtime dependency.
The commands above and the checked-in plan/checker are sufficient to reproduce
the checks with a newly isolated database. The PR records the same outcomes;
its exact final SHA still needs independent review and existing symbolic checks.

Proof: no new law added. Type/contract: existing pinned Cure and boundary checks
ran; the planning checker validates structural JSON/reference properties, not
runtime types. Test: the listed baseline and plan controls passed. Monitoring:
the local PostgreSQL settings above. Upstream: unchanged recorded toolchain and
library Contracts. Historical first-wave dependency merge evidence is separately
linked in [preflight.md](preflight.md) and the manifest, with historical Linux
versus symbolic execution distinguished.

The retained claim commit is `6bcff57fe7b59ec7b0414bf737127302944c5b37`;
the manifest records the session identity and workspace.
The marker was removed in a later commit before PR creation. The unrelated
untracked `graft/` remains untouched; no clean-all-files claim is made.

No runtime capability, provider adoption, catalogue readiness, product completion
or release acceptance follows from this PR. B24.1–B24.3 and later provider/API/
transaction choices remain explicit dispatch blockers. Merge, issue closure,
branch/workspace deletion and independent review are not performed by this worker.
