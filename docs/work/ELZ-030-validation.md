# ELZ-030 integrated validation

Coordinator: Orca `3b13aceb-03fd-42ab-81ca-a11ca986749b`.
Runtime/metadata tree checked: `33cb576bbae6e27128c1dcccc65c58d6cd452345` on `task/ELZ-030`, including
`origin/main` `230cc5b211ef0599fe6a1980286c952111e5e0ae` through normal merges.
This document records the completed local check; independent final review, PR,
CI, merge acceptance and cleanup are separate outstanding gates.

## Exact commands and results

From `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-030`:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test \
  mix setup

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test \
  mix check
```

- `mix setup`: exit **0**, 2026-11-08 **06:32:09–06:32:12 WIB**;
  setup emits no `Result: N passed` line.
- Full `mix check`: exit **0**, **06:32:12–06:44:38 WIB**;
  `Result: 32 passed` (Ash spike), `Result: 561 passed` (root suite),
  **`ELZOO CHECK PASSED`**.
- Selection was **full**: all 26 fixed consumers, zero skipped, the aggregate
  consumer with **all 41 ready IDs**, OTP-only consumer and all root tests.
  The persisted-registry aggregate includes `workflow/context-selection`.
  Aggregate plan/write + test + runtime check took **170.7 seconds**;
  this is one local timing observation, not a speedup or latency guarantee.
- `mix elzoo.ledger`: exit **0**, regenerated from the scoped registry change.
- `python3 scripts/check-claims.py`: exit **0**, `No tracked claim metadata`.
- `git diff --check`: exit **0**; working tree was clean at validation completion.

Exact Cure dependency: `balungpisah/cure-lang`
`208248063d64e621782cd26dd30698ee42850a89`, Elixir **1.20.4**, OTP **29.1.2**.
The author already ran `mix deps.get` and fresh setup after normal-merging PR #85;
this coordinator repeated fresh public setup at the integrated metadata tree.
Logs for this session: `/tmp/elz030-integration/setup.log`, `check.log`,
`results.json`; the durable result and scope are recorded above.

## Integration and limits

Only `workflow/context-selection` was promoted in the task branch registry and
planning rows; its manifest hash and generated ledger were reconciled.
The original `.claims/ELZ-030.md` marker was removed by commit `33cb576bbae6e27128c1dcccc65c58d6cd452345`;
the first-push claim `82e91b1d601604f29f06caec1b923b5e2873cff5` remains in history.
No existing test/assertion or protected CI/compiler/export file was authored here.
The dedicated `elzoo_pieces_test` database was provisioned by the root coordinator
after the task role's `createdb` returned permission denied; no other database was
used or changed by this task.

Proof, type checking, finite tests and upstream assumptions remain separated in
[piece.json](../../pieces/workflow/context-selection/piece.json) and the
[production handoff](ELZ-030-production.md). Full check passing does not turn
success-only laws into progress, optimality, authenticity or universal timing claims.
The host's current snapshot/completeness and native upstream contracts remain Needs.

**Named pre-queue gate:** PR #85 changed upstream-reference bytes in 24 existing
manifests without updating their roadmap hashes. `check-roadmap.py --write` and
`--live` currently reject that inherited drift; it is not part of `mix check`.
The root coordinator explicitly owns its repair as **ELZ-048** and instructed this
branch not to edit those 24 hashes. After that repair merges, normal-merge main,
run `python3 scripts/check-roadmap.py --write`, then plain
`python3 scripts/check-roadmap.py`, and require both to exit 0 before queue entry.
Generated roadmap views remain pending until then. This local validation does not
claim that planning check or final CI has already passed.
