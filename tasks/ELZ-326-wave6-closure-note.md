# ELZ-326 — Record that Wave 6 is accepted, with its open handoff

- Dependencies: ELZ-323, ELZ-324

## Outcome and scope

Record that Wave 6 is accepted: every published Wave 6 task is merged on a
green `main`, in the same form as the Wave 5 closure in
`docs/plans/bot-platform-wave5.md`. This is a coordinator one-PR documents
change: publication and implementation share one `task/ELZ-326` pull request,
and it takes the documents check.

Owned paths:

- `docs/plans/bot-platform-wave6.md`: a new section, "Wave 6 closure and
  open handoff", after "Status and scope";
- `docs/plans/bot-platform.md`: the heading and the Wave 6 sentences of the
  "Waves 4 to 9" paragraph only;
- `docs/choices.md`: a new section, "Limits of the Wave 6 acceptance
  (ELZ-323)", before "Wave 6 coordinator decisions".

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The closure section lists the merged Wave 6 tasks by level with the
   `main` commit whose push check is green: Level 1 ELZ-297 to ELZ-302,
   Level 2 ELZ-303 and ELZ-304, Level 3 ELZ-322 and the root acceptance
   ELZ-323 (PR #755, merged at `2447871f`), the registry-cost tasks ELZ-319,
   ELZ-320 and ELZ-321, and ELZ-324. It names the repairs and process changes
   merged during the wave and points to the Wave 6 coordinator decisions in
   `docs/choices.md`.
2. It repeats the Limits of the ELZ-323 report
   (`docs/research/wave6-count-and-see.md`) and claims no more than that
   report's finite tested composition.
3. It records the open handoff: the RunEngine Run, Unit, evidence and
   transcript stores of the root acceptances run on the RunEngine fixture's
   owner connection, not as `elzoo_app`; the coordinator accepted this for
   ELZ-323 (review blocker B1), the same arrangement as ELZ-286, and ELZ-327
   removes it. It lists the other open issues as non-blocking.
4. It states that Wave 7 is not admitted and waits for the owner's go. No
   Wave 7 task, row or plan is added.
5. `bot-platform.md` no longer says that Wave 6 is planned with tasks still
   published from its page. It states that Waves 4 to 6 are merged, points to
   the closure section and says that Wave 7 waits for the owner. The serial
   rule for later waves is unchanged.
6. `docs/choices.md` gains "Limits of the Wave 6 acceptance (ELZ-323)" in the
   form of the Wave 5 limits section. One entry states that the RunEngine
   stores run on the owner connection until ELZ-327 lands and points to the
   Wave 5 entry "RunEngine Runs on the owner connection" instead of repeating
   it.

The Wave 4 and Wave 5 closures are unchanged. No Contract, task, Piece,
catalogue row or other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One independent review of the claims against the merged PRs and the
   ELZ-323 report, a green exact-head hosted documents check, the PR marked
   ready and the automated reviewer's gate of `AGENTS.md` section 6. The
   coordinator merges on a green `main`.
