# ELZ-043 — Keep a warm dependency cache on every backend runner

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-042 (#72), serial on CI policy files
- Must land before ELZ-038 (#68).

## Outcome

The ELZ-038 investigation (#68, comment "CI wall-time investigation") measured about 14 min of
the 21→44 min main-job increase as cold-cache work: `mix setup` 71→662 s plus a 273 s cache save.
Two causes stay after today's main run warmed the candidate (`refs/heads/main` cache 10156584066):

1. The cache saves only in the post-job step. A failed or timed-out job saves nothing
   (PR #71 attempt 1 timed out, so no warm cache came from it).
2. Each main run warms only the runner that picked it up. After a `mix.lock`/`mix.exs` change,
   the other backend runner stays cold until it gets a main run; PR caches are not shared.

## Scope

- Split `actions/cache` into pinned `actions/cache/restore` + `actions/cache/save`, and save
  dependency state right after `mix setup` succeeds, before `mix check`. Keep the
  runner-specific key and restore-keys. Save only on trusted refs where the current step does.
- Decide, with measurements, whether a key change needs an explicit warm step on each backend
  runner (for example a `workflow_dispatch` or main-only job per runner role). Keep runner
  identity guards. No hosted runners, no third runner.
- Do not restore compiled artifacts across runners or paths. Do not cache root Elzoo BEAMs as a
  substitute for the source-copy boundary.
- Update `docs/development/10-symbolic-ci.md`. Add this body at
  `tasks/ELZ-043-warm-runner-caches.md`. Guard (`scripts/check-ci-runners.py`) must still pass;
  extend its pin checks to the new actions if needed.

## Acceptance

- [ ] A run that fails after `mix setup` still leaves a saved cache (show cache ID and ref).
- [ ] Both backend runners have a main-scoped cache for the current key (show cache list).
- [ ] Guard tests, full `mix check`; CI on PR head and merge commit with runner identity shown.
- [ ] Independent review of the actual diff.

## Limits

Saves cold-run time only. No claim about warm-run speed. Repeated Cure work is a separate item
(#68 remedies 3, 4, 6).
