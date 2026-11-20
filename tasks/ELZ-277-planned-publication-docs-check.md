# ELZ-277 — Give a strictly planned-only publication the documents check

- Dependencies: ELZ-251

## Outcome and scope

The hosted classifier `scripts/ci-change-class.py` treats a strictly
planned-only publication as documentation only, so its pull request gets the
short documents check instead of the full check. The workflow, the merge
queue (`scripts/merge-queue.py`) and the push-run skip decision
(`scripts/ci-skip-decision.py`) use that result through the same classifier
function. This is a CI change: it is never docs-only itself, it is its own
task, and it takes the full hosted check. It is a coordinator one-PR task:
publication and implementation share one `task/ELZ-277` pull request.

Owned paths:

- `scripts/ci-change-class.py`
- `scripts/test-ci-change-class.py`
- `scripts/merge-queue.py`
- `scripts/test-merge-queue.py`
- `scripts/ci-skip-decision.py`
- `scripts/test-ci-skip.py`
- `docs/development/10-symbolic-ci.md`
- `docs/development/13-coordinator.md`
- `AGENTS.md` (section 5, the planned-only paragraph)

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. No Piece, manifest, provider, dependency, pin,
workflow file or runner label changes.

## Required behavior

A change is a strictly planned-only publication when all of these hold for
the exact `git diff --raw` of the change:

1. Every changed path is a regular file that the documentation allowlist
   accepts, or `registry/catalogue.json` or `LEDGER.md`; both of these two
   are modified (status `M`, mode `100644` on both sides).
2. The catalogue at the head equals the catalogue at the base except that
   one or more entries are added: every other top-level field is unchanged,
   and the base entries appear unchanged and in the same order.
3. Each added entry has exactly the fields `id`, `summary`, `disposition`,
   `phase`, `status` and `reason`, all non-empty strings without control
   characters; `status` is `planned`; `id` has the Registry form
   `family/name`; every ID at the head is unique.
4. `LEDGER.md` at the head equals `LEDGER.md` at the base with the ledger row
   of each added entry inserted in ID order, in the exact form that
   `Elzoo.Registry.ledger/1` writes for a planned entry.

The classifier reads both blobs of each of the two files by the object names
that the raw diff gives. It fails closed: any other path or mode, a ready or
deferred added row, a manifest or other extra field, an edited, removed or
reordered existing row, a changed top-level field, a duplicate JSON key or ID,
malformed JSON or UTF-8, a ledger that differs from the expected one, or a
failed Git read keeps today's class. The pure documentation rule is unchanged.

The workflow output and markers stay as they are (`docs_only=true`); the
docs-only check step keeps running `check-roadmap.py`, which compares the
catalogue IDs with the plan.

## Acceptance and evidence

1. Guard tests in `scripts/test-ci-change-class.py` on real Git repositories
   for the accepted shape and for near misses: a ready row, a deferred row, a
   manifest, an edited existing row, a removed or reordered row, a Piece path,
   a stale or hand-edited ledger, a catalogue change without the ledger, and
   a malformed catalogue.
2. Queue and skip-decision tests: the queue merges such a publication on the
   short check and dispatches a full run for a near miss; the push-run skip
   accepts the short shape for such a merge.
3. The classifier on recent real publications: pure additions are accepted,
   publications that edit an existing row are not.
4. The full local gate for scripts (`mix check --affected origin/main`, which
   selects everything for scripts) and `git diff --check`, on a disposable
   database.
5. One independent review; exact-head hosted full check green; mark ready.
   The coordinator merges.
