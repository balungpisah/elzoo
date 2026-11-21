# ELZ-292 — State that the automatic Amp-Thread-ID commit trailer is allowed metadata

- Dependencies: none

## Outcome and scope

Record an owner decision in the workflow rules. Amp adds an `Amp-Thread-ID`
trailer to the commits it makes; about 70 commits on `main` already carry
it. AGENTS.md section 4 allows standard authorship metadata and says that
automatic authorship metadata needs no rewrite or approval, but it also
forbids session links and session identifiers, so the trailer's status is
unclear. The owner decided that this automatic trailer counts as metadata
and is allowed, and that history is not rewritten to remove it.

This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-292` pull request, and it takes the
documents check.

Owned paths:

- `AGENTS.md` (section 4, the public-repository bullet only)
- `docs/development/12-change-class-flow.md` (the matching roles-only bullet
  only)

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

Both places say that the `Amp-Thread-ID` trailer Amp adds automatically is
allowed metadata, that it needs no approval, and that published history is
not rewritten to remove it. Everything else stays: authored repository
content, examples, commit-message prose, and issue/PR prose remain
roles-only, and session links, hostnames, addresses, local paths, database
names, credentials and session identifiers stay out of that authored
content. No other rule changes.

## Acceptance and evidence

1. The diff changes only the two bullets named above, this task file, its
   job row and the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the wording, a green exact-head hosted
   documents check, and the PR marked ready. The coordinator merges on a
   green `main`.
