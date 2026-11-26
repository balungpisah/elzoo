# ELZ-411 — Mark Elzoo's first release

- Dependencies: ELZ-405, ELZ-406, ELZ-407
- Release: V2
- Stage: `release`
- Output: none
- New external dependency: none

## Outcome and scope

Implement [Level 5 (M)](https://github.com/balungpisah/elzoo/blob/main/docs/plans/first-release.md#level-5--the-release-mark-m) with the [owner's Q1–Q4 answers](https://github.com/balungpisah/elzoo/blob/main/docs/plans/first-release.md#owner-answers-2026-11-25), all A. M's own merge commit on `main` is the release commit only if the `symbolic-check.yml` push run for that exact SHA succeeds. M changes no Piece. The release is marked in the documents only: no marker branch, tag, GitHub release, version change or changelog.

1. In `docs/consuming.md`, add “The first release”. Point to M's implementation PR and tell the consumer to find its merge SHA on GitHub, confirm that the `symbolic-check.yml` push run for that exact SHA on `main` succeeded, then check out that SHA and run `mix elzoo.take`. Distinguish this from taking the latest green `main`: a later green repair does not attest the first release, even if it carries the same mark. State the new-ID and migration-note rule for a changed ready Contract; fixes that restore a Contract keep the ID.
2. Update the two bullets in `AGENTS.md` section 4 beginning “Elzoo is not released yet” and “From the first release”, `docs/choices.md` under “In-place change before the first release”, the “Pieces before the first release” decision of 2026-11-14 in `docs/plans/bot-platform.md`, and “Status and scope” in `docs/plans/first-release.md`. Name M's implementation PR as the reference for the release commit, subject to the exact-SHA push check. Q2 A is the owner's ask for the `AGENTS.md` edit. From the release commit on, the new-ID rule applies; jobs published after it take stage `later` until the owner plans the next release.
3. In `docs/plans/release-plan.json`, record the mark in the `status` of `V1-ACCEPT`, `V1B-ACCEPT` and `V2-ACCEPT` by task ID ELZ-411, not by PR number (`AGENTS.md` section 3). Record the post-fixture `manifest_sha256` values of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test` with the mark, since those hashes differ from A's. Check them against the manifest bytes and the ready rows; leave the selectors and A's audit unchanged. Regenerate the roadmap views.

## Acceptance

- One independent review checks that M's base contains the merges of X1–X3 (ELZ-405, ELZ-406, ELZ-407). After A's merge on `main` (`00c842f9`), the only changes to any Piece through M's base must be X1–X3 and the admitted repairs ELZ-408 (`71e5f2b9`) and ELZ-409 (`5ed6b662`). ELZ-410 (PR #1000) recorded those admissions and moved the X1–X3 record-writing baseline to `71e5f2b9`; ELZ-409 is test-only and does not move that baseline. The review also checks that M changes no Piece and that the consuming instructions distinguish M's successful exact-SHA push from a later green repair.
- `python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py` and `git diff --check` pass. `docs/consuming.md` is copied by the exporter and read by tests; M is not docs-only. Run the full gate for this shared change under `AGENTS.md` section 5. The full hosted check on M's exact PR head must pass before merge.
- After merge, the coordinator confirms that the `symbolic-check.yml` push run on `main` for M's exact merge SHA is green. If it remains red after any rerun permitted by `AGENTS.md` section 5, stop: the release is not accepted, and no later commit becomes the release commit without a new owner decision.
