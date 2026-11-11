# ELZ-102 — Prepare Amp orbs with the pinned toolchain and test services

- Phase: development-environment tooling (no catalogue change)
- Catalogue IDs: none
- Dependencies: none

## Outcome

Let fresh Amp orbs (cloud sandboxes where agents work) start with the
repository's pinned toolchain, dependencies and test services ready, instead
of every agent reinstalling them. Amp runs `.agents/setup` once per project
snapshot and `.agents/resume` after each wake.

## Scope

- `.agents/setup`: idempotent, non-interactive. Installs OTP 29.1.2 and Elixir
  1.20.4 (hex.pm builds, SHA-256 checked), Node 24.16.0 (nodejs.org, SHA-256
  checked), PostgreSQL 16 with pgvector and the disposable `elzoo_test`
  role/database/extension as in `symbolic-check.yml`, and the pinned MinIO
  `RELEASE.2025-09-07T16-13-09Z` (same SHA-256 as `scripts/ci-minio.py`) as a
  loopback systemd service with the `elzoo-test` bucket. Exports the toolchain
  PATH, `ELZOO_TEST_DATABASE_URL` and `ELZOO_TEST_S3_*` to login shells, then
  runs `mix setup` and `spikes/gleam_ui/scripts/setup.sh`.
- `.agents/resume`: restarts PostgreSQL and MinIO if needed; no installs; gives
  up after 8 s, inside Amp's 10 s window.
- `spikes/gleam_ui/scripts/setup.sh`: skip `npm ci` while
  `node_modules/.package-lock.json` is newer than `package-lock.json`. A fresh
  checkout (CI) has no `node_modules`, so it still runs `npm ci`.
- `.gitignore`: ignore `/.amp/portals/*`.

No Piece, Contract, ledger, CI workflow, `mix.exs` or pin changes.

## Acceptance

- Cold and warm `.agents/setup` succeed in a fresh Debian 13 orb; the warm run
  downloads and reinstalls nothing.
- From a clean non-interactive login shell: the pinned `erl`/`elixir`/`node`
  resolve, the database and S3 variables are set, and the object-store, lease
  and search-data tests and `spikes/gleam_ui/scripts/check.sh` pass.
- `.agents/resume` brings stopped services back within its budget.
- Hosted Check and Gleam runs pass on the PR head.

## Evidence and limits

Test: the listed scenarios in one Amp orb (Debian 13, 4 vCPU). The orb setup
is a convenience for agents and not CI evidence; the hosted runs remain the
only merge evidence. The cold run is dominated by `mix setup` compiling Cure
(about 11 minutes on 4 vCPU), which later orbs restore from the snapshot.
