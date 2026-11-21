# ELZ-314 — Elzoo.Journal.history/3 reads the account and its page in one statement

- Dependencies: ELZ-297

## Outcome and scope

Repair a Contract defect in `domain/journal`, found by the one-time
other-family recheck that `AGENTS.md` section 6 owes this Piece. The
Contract is unchanged and the Piece ID stays. Task ELZ-297 (Posting rules)
says that `balance/3` and `history/3` run "one read under the tenant scope
(no isolation check: a single read)". On `main`, `history/3` in
`pieces/domain/journal/lib/elzoo/journal.ex` runs two statements: an accounts
`SELECT` for the currency identity, then the postings page in `page/6`. Under
READ COMMITTED each statement has its own snapshot. The account's currency
identity never changes through the Piece, so no wrong page has been shown.
The defect is that the code does not do what the Contract says, and that no
test would notice.

Owned paths: `pieces/domain/journal/lib/**` and `pieces/domain/journal/test/**`;
then, in the last commit, the Piece's `docs/plans/release-plan.json` entry
(`manifest_sha256` only if `piece.json` changes) and the generated views
(`AGENTS.md` section 3). The README and the `contract` of `piece.json` do
not change.

## Required behavior

1. `history/3` issues exactly one SQL statement under the tenant scope after
   the scope's own setup (the `set_config` of `Elzoo.TenantIsolation.transact/3`).
   That statement returns the account's currency identity and the bounded
   page together, and it distinguishes an unknown account from a known
   account with an empty page.
2. Results are unchanged: entries, `next`, `:unknown_account`, `:registry`,
   the `limit` and `after` bounds, and the row-security behavior.
3. `balance/3` already reads once; leave it unless it does not.

## Acceptance and evidence

1. A test counts the statements that `history/3` sends to the Repo, through
   the Repo's query telemetry. It asserts one statement after the scope setup
   for a known account with entries, a known account with an empty page and
   an unknown account. All existing `history/3` cases still pass.
2. Negative control: a temporary edit back to the two-statement read makes
   the new test fail. Revert it and never commit it.
3. `mix test pieces/domain/journal/test`, the local small gate (this Piece
   holds durable money state), `git diff --check`, and the index step 3
   checks.
4. One independent review, a green exact-head hosted `check-piece`, the PR
   marked ready, and the automated reviewer's gate of `AGENTS.md` section 6.
