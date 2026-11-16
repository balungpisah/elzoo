# ELZ-244 — Remove stale live-state text from release-plan.json job statuses

- Dependencies: ELZ-033
- Output: none. No Piece output; a documentation/index repair of `docs/plans/release-plan.json` and its generated views.
- Change class: Documents only.

`AGENTS.md` section 3 states: "Live state. GitHub holds it. Do not write
'claimed', 'PR pending' or a pull request number into release-plan.json."
Thirty-seven published job rows and two proposal rows carry frozen
live-state status text from before their tasks merged: phrases like
"claimed task/ELZ-050; PR pending", "implementation prepared on
task/ELZ-023", "implemented in PR #57; ready on main only once PR #57
merges", "merged on main; coordinator retains acceptance", and
"independent review and acceptance pending". Every named ELZ task is
merged on `main` and its issue is closed; the text is stale.

## Scope

For each stale `jobs` row in `docs/plans/release-plan.json`, replace the
status with the resolved form already used by completed published tasks:
`published <date>` (the task-file commit date already recorded in the
row, or the file's first-commit date where the row has no date). For the
two `RC-*` proposal rows whose superseded text ends in "readiness
pending", drop that suffix; the superseded-by clause stays. No `entries`
disposition, manifest hash, dependency, output or other field changes.
`LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`
are regenerated, not hand-edited.

## Acceptance

- `python3 scripts/check-roadmap.py --write` then
  `python3 scripts/check-roadmap.py` pass.
- `git diff --check` passes.
- No job `status` in `release-plan.json` contains "claimed",
  "PR pending", "PR #", "task/ELZ-", "implementation prepared",
  "acceptance pending", "coordinator retains", or "readiness pending".
- Every changed row's new status is `published <date>` (or the shortened
  superseded form for the two RC rows).
