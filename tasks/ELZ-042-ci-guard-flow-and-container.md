# ELZ-042 — Close two CI guard gaps: flow-style jobs and missing job containers

- Phase: P0 harness (CI policy; `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`)
- Catalogue IDs: none
- Dependencies: ELZ-040 (#69)
- Must land before ELZ-039 (own merge queue), which adds write permissions to CI.

## Outcome

The ELZ-040 review (PR #71 comment 6703507238) found two gaps that already exist on main:

1. A job written in YAML flow style (`job: {runs-on: ubuntu-latest, ...}`) passes the guard and
   would run on a GitHub-hosted runner, while the guard prints "no hosted fallback".
2. The guard does not require a job `container:`. Deleting it makes the job run directly on
   the self-hosted host, and the guard still passes.

## Scope

- Reject flow-style job mappings (or parse them) so every job's `runs-on` is checked.
- Require each backend and Gleam job to keep its pinned `container:` image with `@sha256:`.
- If cheap, reduce false positives from ELZ-040 finding 3 (matches inside `run:` scripts and
  comments), without weakening any rejection.
- Negative controls for each gap: fail on the ELZ-040 guard, pass on the new one; record both.
- Add this task's source body at `tasks/ELZ-042-ci-guard-flow-and-container.md`.

## Acceptance

- [ ] New controls fail on the old guard and pass on the new one.
- [ ] `test-ci-runners.py`, `check-ci-runners.py`, full `mix check` pass; CI passes on PR head
      and merge commit with runner identity shown.
- [ ] Independent review of the actual diff.

## Limits

The guard stays a source convention, not a hostile-YAML parser.
