# ELZ-312 — Test domain/metering correction order against a controlled commit order

- Dependencies: ELZ-299

## Outcome and scope

Repair a test-grounding defect in `domain/metering`, found by the
other-family recheck that `AGENTS.md` section 6 owes this Piece. The Piece's
Contract, library code, README, `piece.json`, Piece ID and catalogue/ready
entry stay unchanged. This is a coordinator one-PR test-only repair
(`AGENTS.md` section 1): publication and implementation share one
`task/ELZ-312` pull request.

Owned implementation paths:

- `pieces/domain/metering/test/elzoo/metering_test.exs`
- `pieces/domain/metering/test/support/metering_test_helper.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Observed defect

The Contract (`piece.json` `contract`; task ELZ-299, `correct/3` and Rules)
says the effective amount is the latest correction by commit order, and that
concurrent corrections are ordered by their commit. The `grounding` of
`piece.json` claims case 2 as test evidence: "corrections held behind the
owner's row lock queue in commit order".

In `metering_test.exs` (case 2, around lines 266-280), corrections `c2` and
`c3` are released together behind the owner's row lock, so the test does not
choose or observe which one commits first. It then asserts that
`effective == List.last(cs).amount` and that the listed corrections equal the
`ORDER BY revision` read. Both sides come from the Piece's own revision
column, so an implementation that orders revisions and the effective amount
by something other than commit order passes. No production ordering fault has
been shown; the defect is that the claim has no test that could fail.

## Required behavior

Add, or change the existing case 2 into, a scenario where the commit order of
two concurrent corrections of one observation is controlled or observed
independently of the Piece's revision column. For example, hold the second
correction behind the first until the first has committed, and record the
commit order the test produced. Then assert, against that order:

1. `observation/3` lists the corrections in that commit order;
2. the effective amount is the amount of the correction that committed last;
3. `totals/3` `known` reflects that effective amount.

Use amounts for which the wrong order gives a different answer. Keep every
existing assertion; add no sleep, retry, skip, tag or timeout change. The
`grounding` text already covers the case; leave `piece.json` unchanged.

## Acceptance and evidence

1. Negative control: a temporary edit to `lib/elzoo/metering.ex` that sets
   the effective amount from the first correction instead of the latest, or
   numbers revisions in another order, makes the new scenario fail.
   Revert it, record the failure, and never commit it.
2. `mix test pieces/domain/metering/test --repeat-until-failure 50`, the small
   gate (`mix check --piece`), `git diff --check`,
   `scripts/ci-change-class.py` and the index step 3 checks.
3. One independent review, a green exact-head hosted `check-piece`, and the
   PR marked ready. The coordinator merges on a green `main`.
