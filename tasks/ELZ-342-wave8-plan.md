# ELZ-342 — Plan Wave 8, Bots talk

- Dependencies: ELZ-338

## Outcome and scope

Write the planning input for Wave 8 ("Bots talk") of the P13 track, in the
form that `docs/plans/bot-platform-wave7.md` used for Wave 7, so that its
levels can be published as tasks after the owner answers its questions.
Wave 7 is accepted: its root consumer acceptance ELZ-338 is merged on
`main`. The owner pre-approved Wave 8 planning ("continue to wave 8 once the
gate open"). The room-life decision of `docs/plans/bot-platform.md` still
gates the registration of Wave 8, so the plan asks it as an owner question
and publishes nothing. This is a coordinator one-PR documents change:
publication and implementation share one `task/ELZ-342` pull request, and
it takes the documents check. It publishes no Piece task and promotes
nothing to ready.

The dependency line names ELZ-338, the Wave 7 root acceptance (V1B). The
Wave 7 closure record ELZ-341 is a separate documents task; this plan does
not depend on it.

Owned path:

- `docs/plans/bot-platform-wave8.md`: a new page.

This task does not edit `docs/plans/bot-platform.md`: ELZ-341 owns its
"Waves 4 to 9" heading and Wave 7 sentences, and the Wave 8 rows of its
tables are pointed to the new page when the first Wave 8 level is
published.

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
   candidate handles" (one disposition for each handle of the Wave 8 rows
   of both tables in `bot-platform.md`), "Deferred items folded in",
   "Dependency levels", and "Provider prerequisites and open questions".
2. It starts from the pruned Wave 8 core in `bot-platform.md` as a proposal,
   not a decision, and does not turn each handle into a Piece. A handle that
   ready Pieces already serve is marked reuse or composition, with the
   Pieces named. A new Piece is proposed only for policy that is missing,
   and an in-place extension of a ready Piece is preferred before the first
   release (`AGENTS.md` section 4).
3. The plan carries the owner's decisions of 2026-11-21 as settled, and
   asks no question about them: the room rollover as a continuation chain
   (one atomic step closes the old Run and creates exactly one successor;
   one correlation ID; each Run links to its predecessor; mail to a
   superseded identity goes to the live tip), the closed input surface of
   `delivery/durable-mailbox`, the parent-close rule of `workflow/delegation`
   (abandon, request cancel as the default, or cancel, per child Run), and
   the pinned recipe version that a child Run and a rollover successor keep
   unless an explicit change says otherwise.
4. "Deferred items folded in" decides each deferred item that the plans,
   `docs/choices.md` or the open issues map to Wave 8, at least:
   `workflow/work-item` (RC-11) and `assembly/task-workflow` (RC-37), the
   Nexus-style call shape for the a2a Pieces, the request-cap note of
   `docs/choices.md` that waits for the room decision, the open decision
   "the turn policies of a room", and the RC-68 and RC-48 exclusions of
   child-Run actions and waits.
5. Each proposed job names its dependencies (task IDs), its new external
   dependency or "none", a Contract sketch, its acceptance with negative
   controls sized to its risk, and the options that it keeps addable in
   place under the owner's standing "no corner" rule.
6. The last level is a mandatory root consumer acceptance with no Piece
   output, in the form of ELZ-338.
7. Each product or provider choice that needs the owner is one numbered
   question with lettered options and a recommendation. The room-life
   decision is one of them. A new dependency or changed pin is its own task
   that merges first. A Contract sketch that depends on an open question
   says so.

No Contract, task, Piece, catalogue row, `docs/choices.md`,
`docs/plans/bot-platform.md`, `docs/plans/bot-platform-wave7.md` or other
plan text changes.

## Acceptance and evidence

1. The diff changes only the owned path, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py` (plain, `--write` and `--live`),
   `python3 scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the dispositions, the source facts against the
   ready manifests and each Contract sketch under the "no corner" rule, a
   green exact-head hosted documents check, the PR marked ready and the
   automated reviewer's gate of `AGENTS.md` section 6. The coordinator
   merges on a green `main`.
