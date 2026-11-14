# ELZ-204 — The test of the implicit correlation of a transformation asserts the whole envelope

- Dependencies: ELZ-007, ELZ-112
- Output: none. A repair of a test of the ready Piece `delivery/transformation`; the Piece ID and its Contract stay.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/delivery/transformation/test/**` only. No file of `lib/`, no example, no `piece.json`, no README, no index file.

The automated review of pull request #217 found that the test of the
bundled example checks only two members of the envelope that the
example makes without a correlation ID in the source.

Facts checked on `main` (confirm each when you start):

- The test "the bundled example shows the public calls and its values
  stay exact" (`test/elzoo/transformation_test.exs`, about 157 to 184)
  compares `result.translated` with the whole expected value. For
  `result.implicit_correlation` it asserts only `correlation_id` and
  `causation_id` (about 178 to 180).
- `translate/3` (`lib/elzoo/transformation.ex`, about 12 to 19) sets the
  producer, the schema, the two IDs and the payload of the new
  envelope.

## Task

Replace the three lines on `result.implicit_correlation` with one
assertion of the whole value, `{:ok, %{...}}`, with each member written
out as a literal, as the assertion on `result.translated` above it does.
Take the expected members from the example file. Change nothing else:
no other test, no file outside the test directory. Contract unchanged.

## Acceptance

- The diff changes only that assertion.
- `mix test pieces/delivery/transformation/test` passes.
- Negative control, by a temporary edit that is reverted: `translate/3`
  changes one member other than the two IDs (for example the
  `schema_version` of the new envelope) only when the source envelope
  has no `correlation_id`. The new assertion fails. Record that the old
  three lines pass with the same edit.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0.
- One independent review, risk low.

## Not in scope

The library code of the Piece, its example, its Contract texts, and any
other Piece.
