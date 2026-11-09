# ELZ-084 — Provide the pgvector extension in the CI database service and the local test database

- Phase: CI prerequisite (protected surface, class S)
- Catalogue IDs: none (no Piece; enables the `integration/search-data` vector slice, ELZ-082)
- Dependencies: none

## Outcome

Make the PostgreSQL `vector` extension available to the disposable test database in every
hosted backend job of `symbolic-check.yml` and document the same for the local test
database, so that ELZ-082 can run its store tests against a real pgvector server and fail
closed when the extension is absent. Today neither has it: the CI service image
`postgres:16-bookworm@sha256:5264710b…` ships no `vector` extension (no `vector*` file in
`/usr/share/postgresql/16/extension/`, checked by running the pinned image on the
orchestrator's host on 2026-11-09), and the host's local test database container runs
the official `postgres:16` image (Debian trixie, 16.15) without it either. The `vector`
extension's control file declares no `trusted = true`, so `CREATE EXTENSION vector`
needs a superuser; the job's `elzoo_test` role cannot create it, and the CI role cannot
create roles in tests (batch-1 finding), so the preparation step must create it.

## Admission record

1. **Responsibility and caller.** Provision one pinned server build that contains the
   extension and create the extension in the test database before tests run. Caller:
   ELZ-082 (`integration/search-data` pgvector store) in `check-root` and in the exported
   consumer job `check-consumers-db`; every other test keeps working unchanged.
2. **Interface and invariant.** The three backend jobs (`check-root`,
   `check-consumers-db`, `check-consumers`) use one service image pinned by digest that
   is the official PostgreSQL 16 image plus the pgvector package, and the "Prepare
   disposable PostgreSQL database" step runs `CREATE EXTENSION vector` as the
   `postgres` superuser in `elzoo_test` and prints the installed extension version next
   to `SHOW server_version`. Invariants: the image stays pinned by digest (never a tag
   alone); the PostgreSQL server version and Debian base stay those of the current pin
   unless the PR states the change; the guard (`scripts/check-ci-runners.py`) and its
   test (`scripts/test-ci-runners.py`) pin the new image line exactly as they pin the
   old one; no job gains a container, a port, a permission or a secret; the runner
   identity gate is unchanged.
3. **Reuse check.** Recommended image: `pgvector/pgvector:0.8.7-pg16-bookworm`, index
   digest `sha256:0dd3149a06e4579a0d70d8fef9945636cd514005e7237deb27f9b67886f8dc4f`
   (linux/amd64 manifest `sha256:c0cd736fe8b8b5d408db56b780570bac404fe518e66e39de624aa46f9aabc60a`),
   published by the pgvector project on Docker Hub on 2026-10-31; a run of that image on
   2026-11-09 showed `PG_VERSION=16.15-1.pgdg12+2` (the same server build as the current
   CI pin) and `vector.control` `default_version = '0.8.7'`. Alternative with a longer
   public record: `0.8.6-pg16-bookworm` (2026-08-13). Not chosen: installing
   `postgresql-16-pgvector` from the PGDG apt repository inside the running service
   container at job start (adds a network fetch and an unpinned package version to every
   job). The worker re-verifies the digest, the server version and the extension version
   at PR time and records them; the extension's license (PostgreSQL License) is recorded
   in the CI documentation.
4. **Split test.** Workflow, guard and guard test change together because the guard pins
   the exact header; the local-database documentation travels in the same PR (class D
   part of a class S change). The ELZ-082 Piece is a separate task and PR.
5. **Failure and evidence.** Dangerous paths: an unpinned or mutable image; a server
   minor change that alters existing test behavior unnoticed; an extension created by a
   non-superuser path that silently fails; a guard that no longer pins the service
   image. Proofs: none. Tests: the guard test's existing mutation cases are updated to the
   new image line (an unpinned tag is rejected); `actionlint` and the guard pass; the PR's
   hosted run shows, in each backend job log, the server version and
   `SELECT extversion FROM pg_extension WHERE extname = 'vector'`; the full hosted run is
   green with no test change. Upstream: the pgvector image build and the extension
   behavior are named, not proved.
6. **Composition record.** No Piece, no Needs change for existing Pieces. Telemetry,
   Config, Control: not applicable (CI configuration). Local host action, documented in
   `docs/development/01-workflow.md` and carried out by the owner or main (not by a
   worker in the repository): recreate the local test database container from the
   pgvector image variant whose Debian base matches the existing data volume
   (`pgvector/pgvector:0.8.7-pg16-trixie`, index digest
   `sha256:9cf8b511f0e9a2c209b61430fc139f1ab9c75edbb31fb1751db6617b246a897a`, to be
   re-verified), keeping the data volume, then run `CREATE EXTENSION vector` as the
   superuser in each disposable test database used by workers. Keeping the same Debian
   base avoids a C library collation change under an existing data directory.

## Scope

- change the `postgres` service image line in the three backend jobs of
  `.github/workflows/symbolic-check.yml` to the selected pinned image;
- extend each job's "Prepare disposable PostgreSQL database" step with
  `CREATE EXTENSION vector` (as `postgres`, in `elzoo_test`) and a version print;
- update `scripts/check-ci-runners.py` (`HOSTED_BACKEND_HEADER`) and
  `scripts/test-ci-runners.py` (the pinned-image mutation case) to the new line;
- document the image, digest, server and extension versions and the local database
  steps in `docs/development/10-symbolic-ci.md` and `docs/development/01-workflow.md`.

## Acceptance

- [ ] The three backend jobs run the selected image by digest; the guard rejects the
      same image by tag alone (updated mutation test).
- [ ] Each backend job log of the PR's hosted run shows the server version and an
      installed `vector` extension version.
- [ ] The PR's hosted run of `symbolic-check.yml` is green on the exact head with no
      test or Piece change.
- [ ] `actionlint`, the guard, `git diff --check` and `mix check --affected <base>` pass.
- [ ] The preparation step runs `psql -d elzoo_test -v ON_ERROR_STOP=1 -c 'CREATE
      EXTENSION vector'` as `postgres` after `createdb` and before `mix setup`, and its log
      shows exactly one `vector` extension row.
- [ ] The reviewer re-verifies the selected image's index and amd64 manifest digests and
      the server and extension versions at the exact digest.
- [ ] Independent review of the workflow and guard change is recorded on the PR.

## Evidence and limits

Guard tests and one hosted run; image facts are observations of the pinned digest on
2026-11-09 and at PR time, not a supply-chain proof. The local host change is a
documented operator action, not CI evidence.

## Out of scope

The ELZ-082 Piece, ANN index tuning, other extensions, PostgreSQL major upgrades, the
gleam workflow.

## Reference

Disposition `integration/search-data` (Needs: "PostgreSQL with the pgvector extension
for the vector slice"); ELZ-064 (precedent for a disposable test service); change-class
table (class S: `.github/**`, `scripts/**`).

## Open questions (none blocks a builder)

1. Image version: 0.8.7 (latest, same server build as the current pin) versus 0.8.6
   (older public record). Recommended: 0.8.7, re-verified at PR time.
2. Whether `check-consumers` (no database Piece consumers today) needs the extension.
   Recommended: yes, the three jobs share one pinned header in the guard.
