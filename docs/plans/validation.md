# ELZ-033 validation record

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text. The quoted output of `check-ci-runners.py` in the table below names the machine as `machine A`; the original output named the machine.

The documentation worker ran these checks in the supplied isolated workspace
`<worktrees>/t3-772a5980`, based on main
`404d159a122d18a22554c5688aa79199e4d5c124`, then normally merged main
`32aef4e7dba40231257e2a91095910377c5c4ab9` (ELZ-010 PR #54) without conflicts.
Both baseline and combined-tree setup/check runs passed; final results below
refer to the combined tree. The implementation is documentation,
planning data, generated planning views and their checker; runtime source and
ready metadata are unchanged relative to the synchronized main. The ELZ-010
runtime, metadata and Oban dependency changes entered only through that main
merge; this adoption task did not edit them. Final review, machine A PR checks, merge acceptance
and task cleanup remain with the dedicated roadmap coordinator.

## Actual commands and results

All Mix processes used `ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`.
`mix.exs` selects the test environment for the public setup/check aliases.

| Command | Actual result |
| --- | --- |
| `graft ask "ELZ-033 product-led roadmap adoption documentation planning and preflights" --source` | Exit 127: `zsh:1: command not found: graft`; used `rg` fallback. |
| `mix setup` | Exit 0 from the fresh checkout, then exit 0 again after the main/dependency update. Dependencies built locally; no Cure cache copied from another checkout. |
| `mix check` with dedicated `ELZOO_TEST_DATABASE_URL` | Exit 0; `Result: 32 passed` for Ash experiment; `Result: 366 passed` for root suite; `ELZOO CHECK PASSED`. Root suite reports 526.0 seconds (5.6s async, 520.3s sync). Includes real Cure compilation, selected laws and negative controls, runtime/provider and independent source-copy consumers. |
| `python3 scripts/check-roadmap.py --write` | Exit 0; generated only `docs/plans/views.md` and `dependencies.mmd`. |
| `python3 scripts/check-roadmap.py --live --self-test` | Exit 0; 97 baseline/current catalogue IDs, 2 separate candidates, 76 jobs, 12 products, acyclic/release-ordered references, generated views agree, 129 local link targets checked, all live published Contract hashes/dependencies match; eight invalid-plan controls rejected. |
| `python3 scripts/check-claims.py` | Exit 0: `No tracked claim metadata`. |
| `python3 scripts/check-ci-runners.py` | Exit 0: `All workflow runner selectors target machine A; no hosted fallback`. |
| `git diff --check` | Exit 0, no output. |
| `git diff --exit-code 32aef4e7dba40231257e2a91095910377c5c4ab9 -- pieces lib test registry LEDGER.md mix.exs mix.lock spikes .github .tool-versions .gitignore .ignore` | Exit 0, no output: runtime, metadata, ledger, pins, lockfiles, workflow and unrelated root ignore files preserved. |

The live Contract check also verifies that the new task file exactly equals
issue #55's body. All earlier task files are unchanged. The pre-merge run also passed with
27 Ash + 300 root checks in 301.8 seconds; those logs are retained separately,
and are not substituted for the combined-tree result. The eight in-memory
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
new server pin. The dedicated cluster was stopped after checking. Machine A
services and their queues were not touched.

## Output locations and evidence limits

Full local outputs are retained at:

```text
<artifact directory>/elzoo-033-validation-2026-11-07-t3-772a5980/
  setup.log                  # original baseline
  check.log                  # original baseline
  check-exit.txt
  roadmap.log
  guards.log
  toolchain.log
  postgres.log
  setup-integrated.log       # main 32aef4e synchronized
  check-integrated.log       # 32 + 366, ELZOO CHECK PASSED
  check-integrated-exit.txt  # 0
  roadmap-integrated.log
  guards-integrated.log
  postgres-integrated.log
```

These outputs are inspection artifacts, not a checkout/runtime dependency.
The commands above and the checked-in plan/checker are sufficient to reproduce
the checks with a newly isolated database. The PR records the same outcomes;
its exact final SHA still needs independent review and existing machine A checks.

Proof: no new law added. Type/contract: existing pinned Cure and boundary checks
ran; the planning checker validates structural JSON/reference properties, not
runtime types. Test: the listed baseline and plan controls passed. Monitoring:
the local PostgreSQL settings above. Upstream: unchanged recorded toolchain and
library Contracts. Historical first-wave dependency merge evidence is separately
linked in [preflight.md](preflight.md) and the manifest, with historical Linux
versus machine A execution distinguished.

The retained claim commit is `6bcff57fe7b59ec7b0414bf737127302944c5b37`;
the manifest records the session identity and workspace.
The marker was removed in a later commit before PR creation. The unrelated
untracked `graft/` remains untouched; no clean-all-files claim is made.

No runtime capability, provider adoption, catalogue readiness, product completion
or release acceptance follows from this PR. B24.1–B24.3 were subsequently selected by the coordinator in preflight.md;
independent decision review and worker Contract acknowledgment remain gates.
Later provider/API/transaction choices remain explicit dispatch blockers. Merge, issue closure,
branch/workspace deletion and independent review are not performed by this worker.


## Coordinator review preparation

The coordinator fast-forwarded its own isolated checkout to worker head
`a0c81dc5292d5102ea44327848a6fa3fbd63e8f9` and independently ran
`python3 scripts/check-roadmap.py --live --self-test`, the claim and runner
guards, and `git diff --check`: all passed. It then recorded B24.1–B24.3's
structural action binding, host-verified evidence and current-authority choices
for independent review. This documentation delta changes no runtime source or
prior task body. The existing worker's full Mix evidence remains attributed
to that worker; the coordinator has not claimed to rerun Mix locally.


## Independent review corrections

Review of `6706a6f` found that the clean-working-tree `git diff --check`
recorded above had not checked the committed PR range. The actual
`git diff --check 32aef4e7dba40231257e2a91095910377c5c4ab9..6706a6f`
failed on generated-view trailing whitespace and a blank EOF. The generator
now strips trailing whitespace and emits one final newline; the regenerated
view is checked against the full base range, not merely the working diff.

The coordinator clarified normalized write-set equality and duplicate-preserving
input validation; required finite consent expiry; concrete release/once-consumption
replay state; and authority containment before initial ALLOW/ASK as well as
release/restore. ELZ-012's grounding handoff is an explicit secondary contribution,
while ELZ-033 owns the evidence index. The checker now rejects duplicate primary
outputs and includes that ninth negative control. These changes require a focused
independent exact-SHA re-check; they do not add runtime capability or alter issue
acceptance. Full Mix evidence above is unchanged runtime regression evidence.
