# ELZ-339 — A shorter wait on the automated reviewer

- Dependencies: ELZ-337

## Outcome and scope

By the owner's decision of 22 November 2026, the wait on an unavailable
automated reviewer in `AGENTS.md` section 6 is shortened, and the extra
review may start without waiting, so that no time is lost. The rule stays
safe: no pull request merges without either a finished automated pass on its
exact head or a finished extra review that replaces it.

Observed on 22 November 2026: when the automated reviewer reviews a head, it
posts within about 3 minutes of the ready mark or the push (2 minutes or
less on #776, #801 and #803; 3 minutes and 2 minutes on #804). A head that it
skips stays silent for more than an hour (#776 at 9850bdb1, #798 at
fa99ba68, #804 at 25268533). The account-wide status check of the automated
reviewer has not yet posted a check run or a commit status on any head, so
no rule depends on it.

This is a coordinator one-PR documents change. Owned paths: `AGENTS.md`
section 6 (the bullet "Do not wait on an unavailable automated reviewer"),
this task file, its no-output job row in `docs/plans/release-plan.json`, and
the generated `docs/plans/views.md` and `docs/plans/dependencies.mmd`.
`docs/development/13-coordinator.md` does not repeat the wait and does not
change. No other rule, Contract, Piece or catalogue entry changes.

## Required behavior

1. The wait is 10 minutes, not 30 minutes, after the later of the ready mark
   and that head's push.
2. The coordinator may start the extra review of the other model family at
   once, at the ready mark or the push. It still replaces the automated
   reviewer's pass only once the 10 minutes have passed with nothing posted
   for the exact head, or once that reviewer says that it is out of quota or
   unavailable.
3. If the automated reviewer posts a pass on the exact head before the queue
   starts, that pass and its threads gate as before, even when the pass comes
   after the 10 minutes or after the extra review is done.
4. Each new or changed line is marked "(owner decision, 2026-11-22)". Every
   other rule of the bullet stays word for word: who does the extra review,
   what it reads, the citation rule, the skip comment, the skip rows and the
   recheck. No rule depends on the status check of the automated reviewer.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, one independent review, a green exact-head docs-only
hosted check, the PR marked ready and the automated reviewer's gate of
`AGENTS.md` section 6 as it stands before this change (30 minutes). The
coordinator merges on a green `main`.
