# ELZ-293 — Record the Wave 5 closure and its open-defect handoff

- Dependencies: ELZ-286

## Outcome and scope

Record that every published Wave 5 task is merged on a green `main`, in the
same form as the Wave 4 closure in `docs/plans/bot-platform-wave4.md`. This
is a coordinator one-PR documents change: publication and implementation
share one `task/ELZ-293` pull request, and it takes the documents check.

Owned paths:

- `docs/plans/bot-platform-wave5.md`: a new section, "Wave 5 closure and
  open-defect handoff", after "Status and scope";
- `docs/plans/bot-platform.md`: the heading and the Wave 5 sentences of the
  "Waves 4 to 9" paragraph only.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The closure section lists the merged Wave 5 tasks by level with the
   `main` commit whose push check is green, names the repairs merged during
   the wave, and points to the coordinator decisions recorded on issues
   #646, #647 and #648.
2. It repeats the limits of the ELZ-286 report and claims no more than that
   report's finite tested composition: no production identity provider, no
   live public MCP endpoint, and no Carbonite audit capture.
3. It lists the open items as non-blocking: ELZ-290 and ELZ-291 in progress,
   the owner decision on #670, and the timing flakes #669 and #547.
4. `bot-platform.md` no longer says that Wave 5 is planned, unregistered or
   publishes no task. It states that Waves 4 and 5 are merged and points to
   the closure section. The serial rule for later waves is unchanged.

No Contract, task, Piece, catalogue row or other plan text changes.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the claims against the merged PRs and
   the ELZ-286 report, a green exact-head hosted documents check, and the
   PR marked ready. The coordinator merges on a green `main`.
