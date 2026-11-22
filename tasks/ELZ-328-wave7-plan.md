# ELZ-328 — Plan Wave 7, Remember and know

- Dependencies: ELZ-286, ELZ-322

## Outcome and scope

Write the planning input for Wave 7 ("Remember and know") of the P13 track,
in the form that `docs/plans/bot-platform-wave6.md` used for Wave 6, so that
its levels can be published as tasks after the owner answers its questions.
The owner approved Wave 7 for planning; Wave 6's root consumer acceptance
ELZ-323 is merged. This is a coordinator one-PR documents change:
publication and implementation share one `task/ELZ-328` pull request, and
it takes the documents check. It publishes no Piece task and promotes
nothing to ready.

The dependency line names V1B jobs only: the Wave 5 acceptance ELZ-286 and
ELZ-322, the last V1B task of Wave 6. ELZ-323 is a V2 job, and a V1B job
cannot name it; it is merged on `main`.

Owned paths:

- `docs/plans/bot-platform-wave7.md`: a new page;
- `docs/plans/bot-platform.md`: in "Deferred rows", the row for RC-39 and
  the Wave 6 row (RC-21, RC-23, RC-08, RC-22, RC-40, RC-31), which says that
  Wave 6 is accepted; in "Waves 4 to 9", the paragraph and the Wave 7 rows of
  both tables.

If the automated reviewer is skipped for this pull request (`AGENTS.md`
section 6), the skip comment is posted on the pull request and the
coordinator files its row in a later change of the coordinator guide; this
task does not edit `docs/development/13-coordinator.md`.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The page has "Status and scope", "Source boundaries checked" (facts read
   from ready manifests and sources at a named `main` commit), "All
   candidate handles" (one disposition for each handle of the Wave 7 rows
   of both tables in `bot-platform.md`), "Deferred items folded in",
   "Dependency levels", and "Provider prerequisites and open questions".
2. It starts from the pruned Wave 7 core in `bot-platform.md` as a proposal,
   not a decision, and does not turn each handle into a Piece. A handle that
   ready Pieces already serve is marked reuse or composition, with the
   Pieces named. A new Piece is proposed only for policy that is missing,
   and an in-place extension of a ready Piece is preferred before the first
   release (`AGENTS.md` section 4).
3. "Deferred items folded in" decides each deferred item that the plans,
   `docs/choices.md` or the open issues map to Wave 7, at least: the
   `runtime/async-work` progress heartbeat (needed or not, and why),
   `assembly/data-pipeline` (RC-39), and the deferred and conditional list
   of the Wave 7 row.
4. Each proposed job names its dependencies (task IDs), its new external
   dependency or "none", a Contract sketch, its acceptance with negative
   controls sized to its risk, and the options that it keeps addable in
   place under the owner's standing "no corner" rule.
5. The last level is a mandatory root consumer acceptance with no Piece
   output, in the form of ELZ-323.
6. Each product or provider choice that needs the owner, including a new
   dependency, a parser library or a PostgreSQL extension in CI and
   `.agents/setup`, is one question with options and a recommendation. A
   new dependency or changed pin is its own task that merges first. A
   Contract sketch that depends on an open question says so.
7. In `bot-platform.md`, the RC-39 row and the Wave 7 rows point to the new
   page, and the Wave 6 row of "Deferred rows" says that Wave 6 is accepted.
   The serial rule for later waves and the other rows do not change.

No Contract, task, Piece, catalogue row, `docs/choices.md`,
`docs/plans/bot-platform-wave6.md` or other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the dispositions and source facts against the
   ready manifests, a green exact-head hosted documents check, and the PR
   marked ready. The coordinator merges on a green `main`.
