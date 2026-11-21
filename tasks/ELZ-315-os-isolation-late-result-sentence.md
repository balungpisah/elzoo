# ELZ-315 — runtime/os-isolation README: the late result follows the killed-Owner residual

- Dependencies: ELZ-305

## Outcome and scope

Repair a README contradiction in `runtime/os-isolation`, found by the
other-family recheck of the range that the automated reviewer skipped on
#703. ELZ-305 added a declared residual: an Owner killed with `:kill`
between retiring its registry row and sending the result gives no result
(README "If an owner dies", and `limits` of `piece.json`). The README
section on `run/3` still says, without exception, that after a shorter
`await_ms` ends the wait, "the late result message still arrives". ELZ-305
kept every other README statement unchanged, so the two now disagree.

The Contract does not change: this sentence states the residual where a
consumer reads about the late result. The Piece ID stays. Owned paths:
`pieces/runtime/os-isolation/README.md`; then, in the last commit, the
generated views if the index step 3 checks change them (`AGENTS.md`
section 3). No code, test or `piece.json` change.

## Required behavior

1. The `run/3` paragraph of the README says that the late result message
   still arrives, except in the killed-Owner residual stated under "If an
   owner dies", and links or points to it.
2. No other README statement changes.

## Acceptance and evidence

`mix test pieces/runtime/os-isolation/test` (unchanged code), the hosted
`check-piece` on the exact head, `git diff --check`, the index step 3
checks, one light review, the PR marked ready, and the automated reviewer's
gate of `AGENTS.md` section 6.
