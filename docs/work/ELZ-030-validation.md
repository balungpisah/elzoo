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
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test \
  mix setup

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test \
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

## ELZ-048 integration resolved

At 2026-11-08 07:03 WIB, normal merge `b8b513db33920e726acf74a28254653dfba453c6` incorporated root-owned ELZ-048
main `97456c8c846e7bfc9e56516c37e6ea1a592f575c`. No Piece source or test
changed in this merge. The inherited 24 hashes were reconciled by that upstream
commit; this task authored only its own rows. The formerly pending planning gate
above is now resolved locally:

- `python3 scripts/check-roadmap.py --write`: exit **0**, views regenerated.
- `python3 scripts/check-roadmap.py`: exit **0**, generated views agree.
- `python3 scripts/check-roadmap.py --live`: exit **0**, all live Contracts match.

Each result reports 97 catalogue IDs, 2 separate candidates, 76 jobs, 12 products
and 136 local links. Final PR/CI/queue/merge acceptance remains separate.

## Final-review regression additions (F1–F4)

Author: Orca `7c1b608d-f91b-4573-b2e7-310670b76a04`, 2026-11-08.
Baseline `664652d4f1d134a26b223ae3042a7d3618197346` includes the ELZ-048
merge and regenerated views above. Test commit
`cde8d20b5f773c11024e16039a11e6619cf5759d` appends three tests (126 lines)
to the existing context-selection suite; every pre-existing test/helper/assertion
is preserved. Production source, README, manifest and example remain byte-identical
to independently reviewed `cc01f8163d60ef13d56152a16f3ffbe4f94d6fa3`.
No Contract, metadata, protected file, dependency or configuration changed in
this stage.

- **F1:** with `now: 100` and `snapshot_at: 95`, the exact-boundary check at 95
  selects its item; an own check at 97 drops with
  `stale_access_check/future_check`; the same ancestor check drops the derivative
  with `stale_access_check/source_stale`. A mutation replacing the snapshot bound
  with `now` in both runtime and reference still passes Cure checking but selects
  all three items. The new scenario asserts that disagreement explicitly.
- **F2:** a trusted node with tenant `other` and `check: nil` drops both an own
  candidate and a derivative using that ancestor with
  `access_denied/binding_mismatch`; an independent valid item is selected.
  Removing both runtime/reference early node-tenant gates still passes Cure
  checking but produces `missing_check` and `source_unchecked`. The scenario
  asserts these incorrect details and their disagreement with the required ones.
- **F3:** a separate test exercises 14 deterministic malformed request/context
  pairs, including nested node, check and reference values, improper lists,
  invalid types and invalid UTF-8. Each returns the expected error class with
  zero calls to Cure `select/4`. The original five-request seam test is unchanged;
  valid denied/missing checks are not classified as malformed.
- **F4 (PR wording):** the laws establish successful-result safety relative to
  the recursive reference evaluator. Runtime and reference share primitive and
  structural helpers, including `has_newer`, `resolve`, `resolve_edges`, `key_eq`,
  `same`, `hash_eq`, `both`, `pos_eq`, `flags_at`, `mark`, `ready_edges` and
  `append_edges`. `resolution_law` is separate from `selected_access_law`.
  These additions make no new proof or independence claim. The reviewer's
  scratch 10,000 oracle cases and 30,000 malformed cases remain independent
  observations, not durable regression tests added by this stage.

### Executed commands and results

Both commands ran from the assigned task worktree:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test \
  mix test pieces/workflow/context-selection/test/elzoo/context_selection_test.exs

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test \
  mix check
```

- Targeted suite: exit **0**, **`Result: 36 passed`**, 27.3 seconds, including
  both new mutation controls. Mutation evidence is scenario disagreement despite
  successful Cure checking, not proof rejection or a failing overall test run.
- Full check at `cde8d20`: exit **0**, **07:06:37–07:17:50 WIB** on
  2026-11-08; **`Result: 32 passed`** (Ash spike),
  **`Result: 564 passed`** (root suite), **`ELZOO CHECK PASSED`**.
  This supersedes the earlier root total of 561 for the three added tests.
- Full selection retained all 26 fixed consumers, zero skipped, and the
  aggregate of all 41 ready IDs. Aggregate total: **165.7 seconds**, a local
  observation only. The worktree stayed clean during the full run.
- `mix setup` was not repeated in this additive-test stage: the coordinator's
  successful setup is recorded above and dependencies/configuration are unchanged.
  Cure remains `208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4,
  OTP 29.1.2; only the authorized `elzoo_pieces_test` database was used.
- Logs: `/tmp/elz030-review-additions/targeted.log`,
  `/tmp/elz030-review-additions/full-check.log`; start metadata in `start.json`.

Independent incremental review of these additions and the ELZ-048 metadata merge,
PR/CI, merge acceptance and cleanup remain coordinator-owned gates. No PR,
merge or queue action was performed in this stage.

Final scope audit: `git diff --check` exited **0**; a byte-prefix comparison
confirmed every existing test/helper/assertion was preserved, and a Git-blob
comparison confirmed all non-test Piece files are unchanged from `cc01f81`.
Only the additive suite and this evidence document differ from `664652d`.
