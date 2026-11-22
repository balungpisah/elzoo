# ELZ-341 — Record that Wave 7 is accepted, with its open handoff

- Dependencies: ELZ-338, ELZ-340

## Outcome and scope

Record that Wave 7 is accepted: every published Wave 7 task is merged on a
green `main`, in the same form as the Wave 6 closure in
`docs/plans/bot-platform-wave6.md` (ELZ-326). This is a coordinator one-PR
documents change: publication and implementation share one `task/ELZ-341`
pull request, and it takes the documents check.

Owned paths:

- `docs/plans/bot-platform-wave7.md`: a new section, "Wave 7 closure and
  open handoff", after "Status and scope";
- `docs/plans/bot-platform.md`: the heading and the Wave 7 sentences of the
  "Waves 4 to 9" paragraph only;
- `docs/choices.md`: a new section, "Limits of the Wave 7 acceptance
  (ELZ-338)", before "Wave 7 coordinator decisions";
- `docs/development/13-coordinator.md`: the "Skipped automated reviews"
  list only, the one owed row for #798.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The closure section lists the merged Wave 7 tasks by level with the
   `main` commit whose push check is green: Level 1 ELZ-329
   (`workflow/citation`, #765, #771), ELZ-331 (`integration/search-data` in
   place, #770, #775) and ELZ-332 (`state/memory-record`, #770, #774), with
   the provider prerequisite ELZ-330 (`floki`, #767); Level 2 ELZ-333
   (`integration/document-parse`, #773, #776); Level 3 ELZ-334
   (`assembly/knowledge-ingest`, #798, #804); Level 4 the root acceptance
   ELZ-338 (#811, #813, merged at `8d1ec7cf`; the push run 45074609664 on
   `8d1ec7cf` is green and reused the exact-head full check 45072346027,
   because the merge tree equals the reviewed head `670b39b1`). It names the
   repairs ELZ-336 (#800, #801) and ELZ-340 (#809, #812) and the process
   changes ELZ-335 (#796), ELZ-337 (#803) and ELZ-339 (#807), and points to
   the Wave 7 coordinator decisions in `docs/choices.md`.
2. It repeats the Limits of the ELZ-338 task file and its report
   (`docs/research/wave7-remember-and-know.md`) and claims no more than that
   report's finite tested composition.
3. It records the open handoff, none of it blocking:
   - a host note from the ELZ-338 review: the rendered block of a citation
     item names its sources, not its `item_id`, so a live model can cite an
     `item_id` only if the host puts it in the item's rendered block;
   - two observations, with no fix here: the flake #670 (ELZ-176 YAML
     `bounded_time`) recurred in the ELZ-338 local full gate, and the
     aggregate consumer of `test/export_test.exs` took 1,471 s of its
     1,500 s limit on a 4-CPU orb (#814);
   - the open items carried from Wave 6 that are still open.
4. It states that Wave 8 planning starts next, by the owner's pre-approval
   ("continue to wave 8 once the gate open"), and that the room-life
   decision of `bot-platform.md` still gates Wave 8's registration. No
   Wave 8 task, row or plan is added.
5. `bot-platform.md` no longer says that Wave 7 is planned with tasks still
   published from its page. It states that Waves 4 to 7 are merged, points
   to the closure section and says that Wave 8 planning starts next. The
   serial rule for later waves is unchanged.
6. `docs/choices.md` gains "Limits of the Wave 7 acceptance (ELZ-338)" in
   the form of the Wave 6 limits section.
7. The "Skipped automated reviews" list of the coordinator guide gains the
   owed row for #798: skipped range `06e50161..fa99ba68`, why "nothing posted
   for the head 30 minutes after its push; the other-family fallback review
   was the gate", as the skip comment on #798 records (the 30-minute wait was
   the rule before ELZ-339). No other row, rule or step changes.

The Wave 4, Wave 5 and Wave 6 closures are unchanged. No Contract, task,
Piece, catalogue row or other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py` (plain, `--write` and `--live`),
   `python3 scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the claims against the merged PRs, the ELZ-338
   task file and its report, a green exact-head hosted documents check, the
   PR marked ready and the automated reviewer's gate of `AGENTS.md`
   section 6. The coordinator merges on a green `main`.
