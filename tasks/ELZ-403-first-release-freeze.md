# ELZ-403 — Freeze the first-release selected set and record formats

- Dependencies: ELZ-387, ELZ-389, ELZ-390, ELZ-391, ELZ-392, ELZ-393, ELZ-394, ELZ-395, ELZ-396, ELZ-397, ELZ-398, ELZ-399, ELZ-400, ELZ-401, ELZ-402
- Release: V2
- Stage: `release`
- New external dependency: none

## Publication precondition

The four pre-freeze rechecks are complete:

- [`domain/journal`](https://github.com/balungpisah/elzoo/pull/698#issuecomment-7153390498): no findings.
- [`domain/metering`](https://github.com/balungpisah/elzoo/pull/696#issuecomment-7153375303): no findings.
- [`delivery/dead-letter-store`](https://github.com/balungpisah/elzoo/pull/699#issuecomment-7153399794): the purge finding became ELZ-397; the existing generation limit was confirmed.
- [Skipped automated review recheck](https://github.com/balungpisah/elzoo/pull/798#issuecomment-7153393924): no findings.

## Outcome and scope

Implement Level 2 of the [first-release plan](../docs/plans/first-release.md#level-2--the-freeze-f) with the owner's Q1–Q4 answers, all A. At base `edd27760`, ELZ-387 and every Level 1 task have merged. The coordinator also admitted ELZ-401 (issue #975, for #969) and ELZ-402 (issue #976, for #967). Both have merged and stay in V1B at stage `pieces`.

- In `docs/plans/release-plan.json`, move RC-01, RC-04, RC-06, RC-09, RC-17, RC-20, RC-24, RC-27, RC-28, RC-29, RC-30, RC-31, RC-42 and RC-43 to `later` for the plan's stated reasons. Do not delete rows or change their reasons. Add `later` and `release` to the existing excluded stages of V1, V1B and V2 only. Set each of those gate statuses to `frozen by F; acceptance A`.
- Correct ELZ-028's stale blocked status to the dated publication form. Keep all product job lists; update the limits of P01, P02, P04, P07, P08, P10 and P11 to name their deferred jobs. The first release supplies none of P11 and selects no payment provider for P10.
- In `docs/plans/roadmap.md`, update the gate-selection sentence. In `docs/plans/first-release.md`, state the frozen job lists and freeze rules at the base, with 106 V1, 265 V1B and 29 V2 jobs, and the `manifest_sha256` of every ready row (70, 75 and 7 respectively). Record the GitHub merge commits of the prerequisite work and the two admitted repairs under the release plan's observations.
- Publication and implementation share one coordinator-owned documents-only PR. Publication adds this task file and its no-output job row. Regenerate the ledger and roadmap views; no catalogue entry, Piece, manifest, executable input or selector logic changes. F freezes the set and record formats when it merges; release acceptance, fixtures and the release mark are separate tasks.

## Acceptance

- `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`, `python3 scripts/check-roadmap.py`, `python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py` and `git diff --check` exit 0. Compare each stated frozen job list with the roadmap's actual derived list using a script and record the result.
- `scripts/ci-change-class.py` classifies the exact diff as docs-only. Stop on any other class or on a list discrepancy that the plan's reasons do not settle; do not change a selector or a job's reasons to force agreement.
- Independent review checks the moved rows against the plan's reasons and the exact lists against the derived gates. The exact-head hosted docs-only check passes. No gate is accepted by this task.
