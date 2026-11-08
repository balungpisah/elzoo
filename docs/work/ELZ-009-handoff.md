# ELZ-009 — WIP checkpoint handoff (NOT ACCEPTED)

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

Status: **work in progress, not accepted, no PR.** Stopped at a safe checkpoint
by user scope change ("Stop at ELZ-009 at a safe checkpoint ... so other agent
can continue working on it"). Any agent may adopt `task/ELZ-009` immediately
from this commit (see issue #9 handoff comment); continue the branch with
normal fast-forward pushes, never force/rebase/delete.

## Authority

- Approved Contract: `docs/work/ELZ-009.md` at
  `c8b247c2e68bb74ab35716168763e211138e5749`, early approval
  https://github.com/balungpisah/elzoo/issues/9#issuecomment-6680918336
  (reviewer devin-7a2dbe0b1dad443fa0209faf5cec6e26).
- Binding review conditions: (1) truncation compares head with the fold's
  `cursor.applied` incl. checkpoint seed — implemented in `Elzoo.DurableLog`
  replay, tested (D18 retain-through-head non-truncation); (2) gap-only damage
  — decided: Writer init refuses any damaged seed incl. gap-only, readers still
  return the damaged model; documented in `docs/work/ELZ-009.md` and tested.
- Implementation clarifications recorded in `docs/work/ELZ-009.md`
  ("Implementation clarifications"): `Checkpoint.take/4` store form
  `{store, replay_state, limits}`; common portable input domain
  (≤2^63−1 sequences/revisions, ≤2^31−1 versions/positions, UTF-8 without NUL
  for stream/kind/destination, existing rejection reasons). These must be
  inspected by the final independent review.
- Live issue #9 body is authoritative; re-fetch it and `origin/main` before
  continuing (base was `7333622709ffa4ee800066538ec2424dfc7dce6e`).

## Implemented (on branch)

| Commit | Content |
| --- | --- |
| 49eb65e | Cure `Elzoo.Replay` + laws L1a–L5 and two negative controls wired into `mix check`; `Elzoo.DurableLog` core (records, canonical bytes/digest, validation, static preflight, `replay/3`) |
| 33d71de | Store behaviour, confirmations, Memory double with fault injection, `Elzoo.Checkpoint`, `Elzoo.Outbox` |
| 6217445 | `Elzoo.DurableLog.Writer`, `Elzoo.DurableLog.Conformance` K1–K11, root `test/durable_state_test.exs` |
| 6c52bb5 | `integration/sql` Postgres adapter + migration, fail-closed `ELZOO_TEST_DATABASE_URL` harness, PG K1–K11 + D11/D15/D17/D19, ecto_sql 3.14.0 / postgrex 0.22.4 pins, CI Postgres steps in `.github/workflows/symbolic-check.yml` |
| f6a5dcb | AshPostgres 2.15.2 K1–K5/K8 subset in `spikes/ash_foundation`, Reactor kill probe, disk_log negative comparison; selection Ecto/Postgrex recorded in Contract note |
| this checkpoint | WIP metadata: four `piece.json` + READMEs, `registry/catalogue.json`, regenerated `LEDGER.md` (via `mix elzoo.ledger`), copied-source export test extension, PG test-support moved into `pieces/integration/sql/test/support/` |

## Missing / unverified (next actions, in order)

1. Audit the WIP metadata commit: piece.json source lists, deps, providers,
   operational applicability and grounding against the Contract tables; no
   durability/exactly-once claims.
2. Docs still to update: `docs/architecture.md`, `docs/catalogue.md`,
   `docs/dependencies.md`, `docs/cure-notes.md`,
   `docs/development/01-workflow.md`, `docs/development/10-symbolic-ci.md`;
   flip `docs/work/ELZ-009.md` status from proposal to implemented.
3. Run full `MIX_ENV=test mix check` (NOT run since step 2 — last full pass was
   at 33d71de: 225 passed, ELZOO CHECK PASSED), including the extended
   `test/export_test.exs` (not yet run), and the spike suite.
4. Remove `.claims/ELZ-009.md` in a commit before the PR (keep history);
   then `python3 scripts/check-claims.py` must pass.
5. Open PR (fetch template), wait for symbolic CI (check + gleam jobs; the new
   CI Postgres step has never run in the container), independent final
   exact-SHA review (incl. CI/Postgres harness change and the two
   clarifications), then integration merge, merge-commit CI, cleanup, issue
   closure — by the authorized stages only.

## Commands actually run at this checkpoint

With `ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`,
`ELZOO_TEST_DATABASE_URL=ecto://elzoo_test:…@localhost/elzoo_test`:

- `MIX_ENV=test mix test pieces/state pieces/integration/sql test/durable_state_test.exs test/durable_log_disk_log_test.exs --warnings-as-errors` → `Result: 94 passed`
- `mix format` on `test/export_test.exs`, then `mix format --check-formatted` (rerun before commit)
- `MIX_ENV=test mix elzoo.ledger` → `Wrote LEDGER.md`
- `git diff --check` → exit 0

Earlier stage evidence (from step reports): step-4 targeted 91 passed with
PG 14.24 monitored `fsync=on synchronous_commit=on`; spike 27 passed;
disk_log negatives 3 passed; fail-closed messages verified for missing (exit 1)
and unreachable (exit 2) URLs; `check-ci-runners.py` symbolic-only.

## Recreating the environment

- Toolchain: Elixir 1.20.4 / OTP 29.1.2 (Hex precompiled builds), Cure pinned
  by `mix.lock` at a004c335; `MIX_ENV=test mix setup` on a fresh worktree.
- Disposable local PostgreSQL only (never production/user DBs): e.g.
  `sudo apt-get install -y postgresql`, then
  `sudo -u postgres psql -c "create role elzoo_test login password '<your throwaway password>'"`,
  `sudo -u postgres createdb -O elzoo_test elzoo_test`,
  `export ELZOO_TEST_DATABASE_URL=ecto://elzoo_test:…@localhost/elzoo_test`.
  Throwaway test-only credentials; tests fail closed without the variable.
- Do not copy Cure generated caches between checkout paths.

## Limits

Finite local tests over Memory and a local PG 14 cluster; Cure laws cover only
supplied-decision `count_step`. No WAL, replication, exactly-once or universal
durability claim; disk/fsync semantics are PostgreSQL's upstream contract.
