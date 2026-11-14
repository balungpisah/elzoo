# ELZ-203 — The provider stream states that a completion already received can return just after the total deadline

- Dependencies: ELZ-143, ELZ-156
- Output: none. One stated Limit of the ready Piece `delivery/provider-stream`; no code changes, the Piece ID stays.
- Change class: Piece-only (documents of a Piece and its `piece.json`), in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/delivery/provider-stream/README.md` and `pieces/delivery/provider-stream/piece.json` only, and the index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row). No file of `lib/` or `test/`.

The automated review of pull request #311 found that a call can return
`{:complete, _}` a moment after `total_timeout_ms` has ended. The
finding is true at the edge, and the overrun is small and bounded. This
task states it; it does not add a check. The reason for that choice is
under "Why a Limit".

Facts checked on `main` (lines of `lib/elzoo/provider_stream.ex` at the
time of writing; confirm each when you start, and if one differs, stop
and ask):

- `loop/1` (about 104 to 134) waits with `receive ... after
  remaining(s)`. A message that is already in the mailbox is taken
  before the `after` clause, also when `remaining(s)` is 0.
- `done/2` for a stopped protocol (about 141 to 153) waits for the end
  of the HTTP worker and returns `{:complete, ...}`. It does not compare
  the clock with the deadline. The worker ends right after it sends
  `:done` (about line 241).
- `offer/3` (about 173 to 189) waits at most
  `min(ack_timeout_ms, remaining(s))` for the sink, so no sink wait goes
  past the deadline.
- The HTTP worker waits for the reply to each block before it reads on,
  so at most one block and the final `:done` can be in the mailbox.
- The README says of `total_timeout_ms`: "the whole call" (about line
  28) and that "the end of `total_timeout_ms`" closes the request (about
  115 to 116). `piece.json` gives the same settings in its Config
  contract (about line 110) and has no sentence on a completion at the
  deadline.

## Why a Limit

A check in `done/2` would be two lines. But the case needs a message
that is already in the mailbox at the instant the deadline passes, and
the Piece has only a loopback seam: no test of the Piece can make that
instant on purpose. A check with no test that can fail would be a claim
with no evidence. The stated Limit is the smallest honest repair.

## Task

Add one Limit to the README (in the paragraph on `total_timeout_ms`,
about 111 to 117) and the same sentence to `limits` of `piece.json`:

> The total deadline bounds each wait of the call. It is not compared
> once more when the stream ends: a block or the end of the stream that
> the call has already received when `total_timeout_ms` ends is still
> handled, so a call can return `complete`, or another fixed result,
> shortly after the deadline. Nothing waits for the peer or for the sink
> after the deadline.

Change no other sentence. The changed Contract text is this Limit.
`piece.json` changes, so the `manifest_sha256` of the index row follows
in the last commit before the pull request is opened (in-place change of
a ready Piece, same Piece ID; Elzoo is not released).

## Acceptance

- The diff changes only the README and `piece.json` of the Piece and the
  index and generated files of AGENTS.md section 3.
- Each clause of the Limit is true of the code at the head; the pull
  request body names the line of the code for each clause under
  `Assumptions:` (read in code, not tested).
- `mix test pieces/delivery/provider-stream/test` passes unchanged, then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0.
- One independent review, risk low.

## Not in scope

A deadline check at completion, a test seam for the clock, the wait for
the end of the HTTP worker in `done/2`, `delivery/data-stream`, and any
other Piece.
