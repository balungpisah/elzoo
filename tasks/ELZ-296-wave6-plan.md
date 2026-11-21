# ELZ-296 — Plan Wave 6, Count and see

- Dependencies: ELZ-286

## Outcome and scope

Write the planning input for Wave 6 ("Count and see") of the P13 track, in
the form that `docs/plans/bot-platform-wave5.md` used for Wave 5, so that
its levels can be published as tasks. Fold in #679: the row-status table of
`docs/plans/bot-platform.md` still says that the Wave 5 rows change "when
that wave is registered". This is a coordinator one-PR documents change:
publication and implementation share one `task/ELZ-296` pull request, and
it takes the documents check. It publishes no Piece task and promotes
nothing to ready.

Owned paths:

- `docs/plans/bot-platform-wave6.md`: a new page;
- `docs/plans/bot-platform.md`: in "Deferred rows", the rows for RC-07,
  RC-09 and RC-20 and for the Wave 6 rows; in "Waves 4 to 9", the
  paragraph and the Wave 6 rows of both tables.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The page has "Status and scope", "Source boundaries checked" (facts read
   from ready manifests and sources at a named `main` commit), "All
   candidate handles" (one disposition for each handle of the Wave 6 rows
   of both tables in `bot-platform.md`, and for `domain/entitlement`, which
   the Wave 5 plan moved to Wave 6), "Dependency levels", and "Provider
   prerequisites and open questions".
2. It starts from the pruned Wave 6 core in `bot-platform.md` and does not
   turn each handle into a Piece. A handle that ready Pieces already serve
   is marked reuse or composition, with the Pieces named. A new Piece is
   proposed only for policy that is missing.
3. Each proposed Piece names its dependencies (task IDs), its new external
   dependency or "none", and a Contract sketch with its acceptance
   scenarios, sized to its risk. The Level 1 sketches are complete enough
   to write their tasks.
4. The last level is a mandatory root consumer acceptance with no Piece
   output, in the form of ELZ-286.
5. The ELZ-286 limits stay recorded limits: no identity provider in core, no
   Carbonite audit capture in the Wave 5 acceptance, no live public MCP
   endpoint. When a Wave 6 job needs a real identity provider, a live
   public MCP endpoint or audit capture, the plan admits that as its own
   task inside Wave 6, with its level; it does not skip it.
6. Each product or provider choice that needs the owner is listed as one
   question with options and a recommendation. A Contract sketch that
   depends on an open question says so.
7. In `bot-platform.md`, the row for RC-07, RC-09 and RC-20 states their
   outcome: `domain/membership` ready (ELZ-269), `integration/auth-policy`
   a composition with no Piece, `domain/policy-rules` conditional, and
   `domain/entitlement` placed by this plan. The Wave 6 rows point to the
   new page. The serial rule for later waves and the other rows do not
   change.

No Contract, task, Piece, catalogue row, `docs/choices.md` or other plan
text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the dispositions and source facts against the
   ready manifests, a green exact-head hosted documents check, and the PR
   marked ready. The coordinator merges on a green `main`.
