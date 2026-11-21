# ELZ-308 — Record the Continuum ideas for Waves 8 and 9 and the first release

- Dependencies: none

## Outcome and scope

The coordinator evaluated Continuum, an Elixir library for durable
workflows (Hex `continuum` v0.9.3, source commit `65efcee`, Apache-2.0), on
2026-11-21. The owner decided (2026-11-21) that Elzoo does not adopt it, and
that four of its ideas go into the drafting notes of later waves and of the
first release. This task records those decisions. It writes no Contract,
publishes no Piece task and changes no catalogue row.

This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-308` pull request, and it takes the
documents check.

Owned paths:

- `docs/plans/bot-platform.md`: one block of owner decisions dated
  2026-11-21, after the Wave 6 block and before the table of open
  decisions;
- `docs/dependencies.md`: one row in "External library candidates".

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. **Wave 8, `delivery/room` and `delivery/durable-mailbox`: room rollover
   as a continuation chain.** One atomic step closes the old Run and
   creates exactly one successor; the chain has one correlation ID, and
   each Run links to the Run before it; mail sent to a superseded identity
   goes to the live tip. The note says that this fits the recommended
   candidate 1 of the room-life decision, which stays open, and that
   `assembly/run-engine` keeps its Contract.
2. **Wave 8, `delivery/durable-mailbox`: a closed input surface.** Message
   names are declared with their validators, and a message with an
   undeclared name or a failing validator is refused before the mailbox
   write.
3. **Wave 9, `assembly/ledger-checkout` and `domain/payment-lifecycle`:
   saga rules.** A compensation is registered with the step that
   succeeded; compensations run in reverse order by default and in
   parallel only when declared; each compensation is idempotent with its
   own key; and a failed compensation is its own recorded outcome.
4. **First release:** add frozen record fixtures to the tests of
   `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test`
   when the first release freezes their record formats, and not before.
5. `docs/dependencies.md` lists Continuum as evaluated and not adopted,
   with the version and commit, and gives the reasons in one line: it is a
   second engine for a boundary that ready Pieces own; its automatic
   retries after an unknown outcome conflict with `delivery/effect-intent`;
   its replay needs a determinism checker; and it brings its own
   application, tables and `phoenix_pubsub` into core. An application may
   still use it next to copied Pieces.

No other document changes. The block names the owner decision and its
date. It holds no session link.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the wording, a green exact-head hosted
   documents check and the PR marked ready; the coordinator starts the
   queue on a green `main` after the automated reviewer's finished pass, or
   after the extra review of `AGENTS.md` section 6 when that pass does not
   come.
