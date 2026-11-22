# ELZ-336 — domain/pricing: state that at most 3072 rows can be priced

- Dependencies: ELZ-324

## Outcome and scope

Defect #794, found by the automated reviewer's recheck of #753: the
`domain/pricing` README ("Usage" section and limits paragraph) and
`piece.json` say that a usage takes 0..4096 rows, and that the host builds the
rows of a larger period "up to the 4096 rows this Piece takes". That bound is
accepted, but it cannot be priced. On `main`, `usage?/1` in
`pieces/domain/pricing/lib/elzoo/pricing.ex` accepts at most `@max_rows` 4096
rows, unique on `{provider_id, model_id, unit, source}`, and `source` has
three values (`:estimated`, `:provider_reported`, `:unknown`). Then `price/3`
needs a card line for each row's key `{provider_id, model_id, unit}`
(`:unpriced_unit` otherwise), and a card has at most `@max_lines` 1024 lines,
unique on that key. So a usage prices only when each row's key has a card
line: at most 3 × the card's lines rows, and at most 3072 with the 1024-line
ceiling. A usage of 3073..4096 valid rows is always
`{:error, :unpriced_unit}`, whatever the card.

The behavior is safe (an error, never a wrong charge); the defect is the
documented bound. Coordinator decision: change no code and no bound. State
the effective limit next to the 4096 bound, and add one regression test of the
boundary through the public API.

This changes `domain/pricing` in place before the first release (same Piece
ID): the Contract text gains the effective limit; every result of every
function is unchanged. Owned paths: `pieces/domain/pricing/README.md`,
`pieces/domain/pricing/piece.json` and
`pieces/domain/pricing/test/elzoo/pricing_test.exs`; then, in the last commit,
the Piece's `docs/plans/release-plan.json` entry (`manifest_sha256`, and
`note` equal to the new `contract`) and the generated views (`AGENTS.md`
section 3). No change to `lib/`, `cure/` or `examples/`, and no other Piece
changes.

## Required behavior

1. README "Usage": next to "`rows` a proper list of 0..4096", state that a
   usage prices only when each row's key `{provider_id, model_id, unit}` has
   a card line, so at most 3 × the card's lines rows are priced (3072 with
   1024 lines), and a larger usage is `:unpriced_unit`. The sentence on the
   rows of a larger period ("up to the 4096 rows this Piece takes") names the
   same limit.
2. README limits paragraph: the sentence that ends "up to 4096 rows" states
   the same effective limit (at most 3 × the card's lines, 3072 with the
   1024-line ceiling).
3. `piece.json`: the same effective limit next to each 4096 bound: in
   `contract` (after "usage {tenant, period, rows} of 0..4096 rows"), in the
   `limits` entry that ends "up to 4096 rows", and in the
   `operations.config` contract ("0..4096 rows"). The test claim in
   `grounding` names the new scenario. Every other clause is unchanged.
4. `lib/`, `cure/`, `examples/`, `@max_rows` and `@max_lines` are unchanged.

## Acceptance and evidence

1. One regression test in `pieces/domain/pricing/test/elzoo/pricing_test.exs`
   through `Elzoo.Pricing.price/3`, the boundary pair on one full 1024-line
   card with 1024 distinct keys:
   - 3072 valid rows (each key in each of the three sources) price, with
     expected line and total amounts written out by hand, not computed by the
     Piece;
   - the same rows and one more valid row, unique on its key and source
     (3073 rows, so its key has no card line), give
     `{:error, :unpriced_unit}`.
2. Negative control, a temporary edit reverted and never committed: the test
   made to expect the 3073-row usage to price must fail; record the failure in
   the PR body.
3. `contract` in `piece.json` names the effective limit, and the release-plan
   entry has the new `manifest_sha256` of `piece.json` at the head and `note`
   equal to `contract`.
4. `mix test pieces/domain/pricing/test`, the local small gate (`mix check
   --piece "$(git merge-base origin/main HEAD)"`), `git diff --check`, and the
   index step 3 checks (`mix elzoo.ledger`, `python3
   scripts/check-roadmap.py --write`, `python3 scripts/check-roadmap.py`).
5. One light independent review (`AGENTS.md` section 6), a green exact-head
   hosted `check-piece`, the PR marked ready, and the automated reviewer's
   gate of `AGENTS.md` section 6. The PR closes #794 and this task's issue.
