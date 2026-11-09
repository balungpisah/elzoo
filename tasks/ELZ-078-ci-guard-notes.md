# ELZ-078 — CI guard: case-insensitive cache-save pattern, marker comment, exact test assertion

- Phase: P0 harness (CI guard and its tests only; `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `docs/development/10-symbolic-ci.md`, this task copy)
- Catalogue IDs: none
- Dependencies: ELZ-073 (#136, PR #144) merged (f511841): the guard rules this task refines come from that pull request.
- Review: class S (protected surface: the CI guard; guard and tests only, no workflow change). One narrow independent review of the diff; Devin findings dispositioned.

## Outcome

Owner decision 2026-11-09 (18:25 WIB, relayed by the coordinator): the three non-blocking notes of the narrow re-review of ELZ-073 (cd76681..679606d; recorded on #136) are done as one small pull request now, while the context is fresh.

## Scope

1. **Case-insensitive cache-save pattern** (`scripts/check-ci-runners.py`, the check that only `check-root` saves caches, with exactly two save steps): the pattern for `actions/cache` and `actions/cache/save` becomes case-insensitive (`re.IGNORECASE`), because the pinned-action check allows capitals in an action name and GitHub resolves action names without regard to case. A test: a save step written `Actions/Cache/Save@...` or `actions/Cache@...` in a job other than `check-root`, and a third save in `check-root` written with capitals, are refused with the existing message.
2. **Marker comment** (same file, the part-marker check): a comment that the check finds only a part marker written in full on one line, as for the other markers of the guard; a marker built in a shell script (a printf of two pieces) passes it. The guide sentence "the guard rejects a part marker on any line of the workflow" says "written in full".
3. **Exact assertion** (`scripts/test-ci-runners.py`, `test_a_key_cannot_be_appended_to_a_pinned_step`): the four cases assert the pinned-step message with the job name (`the pinned step "<step>" is missing or changed (<job>)`), not only a non-empty stderr. If one case shows another message, the test states that message and the reason.

## Acceptance

- [ ] The three changes are in; `python3 scripts/test-ci-runners.py`, `check-ci-runners.py`, `test-merge-queue.py`, `test-ci-skip.py`, `test-ci-minio.py`, `test-ci-change-class.py`, `actionlint`, `git diff --check` exit 0.
- [ ] Negative controls: the guard without `re.IGNORECASE` fails the new capital-letter tests; a test whose assertion is weakened back to a non-empty stderr is not accepted (the four cases name their message).
- [ ] The full run of the pull request passes on the five-job shape (run and job IDs, minutes); the queue merges on it.
- [ ] One narrow independent review of the diff; Devin findings dispositioned.

## Limits

No workflow change, no change of any evidence rule, no new guard rule: the guard still sees only text written in full (a shell-built marker, a step that rewrites `scripts/run-ci-check.sh`). A change of the scripts and the guard tests is code, so this pull request runs the full check (about 11 minutes) and is not a documentation-only change.
