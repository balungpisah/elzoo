# ELZ-091 amendment 1 (proposed): three consumer-count literals in protected tests

Status: **proposed**, for the main coordinator's decision on issue #165. Nothing in the two protected test files
changes before that decision.

Reason: early review finding 1 ([ELZ-091-early-review.md](ELZ-091-early-review.md)). A 27th tagged per-ID consumer
(`integration/ai-text`) makes three literal counts false: `test/export_test.exs` `length(per_id) == 26` and
`length(remaining) == length(tests) - 25` (the skipped consumers plus the aggregate for the
`delivery/transformation` selection), and `test/check_selection_test.exs` `length(selection.skipped) == 25`. No
route keeps them true without omitting the required consumer or weakening a count. Every identity, equality,
PostgreSQL-list, partition and limit assertion stays unchanged.

Raw live body (Python `json.loads(gh issue view 165 --json body)["body"]`, UTF-8, LF only, 6471 characters):
sha256 `9fbb2f1fb3d46626de50cbc81b042d30e6a798be4ee9548c59ae8c4a0ecd3aab`.

Proposed body: [ELZ-091-amendment-1-body.md](ELZ-091-amendment-1-body.md) (exact bytes, no trailing newline added),
sha256 `0dcc58cd2e2656c024b6bdcd48068ae500a5dd30bf2a5401c6e4419f44c83bc9`.

Exact replacements against the raw body (each occurs once):

### Change 1

Before:

````text
   (`test/support/cure_consumer_case_test_helper.exs`), keeping the existing equality assertions of
   `test/export_test.exs` true;
````

After:

````text
   (`test/support/cure_consumer_case_test_helper.exs`), keeping the existing equality assertions of
   `test/export_test.exs` true (amendment 1: only three consumer-count literals change, see Scope);
````

### Change 2

Before:

````text
   existing consumers and their assertions are unchanged; a Piece
````

After:

````text
   existing consumers and their assertions are unchanged (except the three count literals of amendment 1); a Piece
````

### Change 3

Before:

````text
- `test/support/cure_consumer_case_test_helper.exs`: the matching consumer ID; write the merged install
  configuration into copied consumers;

````

After:

````text
- `test/support/cure_consumer_case_test_helper.exs`: the matching consumer ID; write the merged install
  configuration into copied consumers;
- amendment 1: in `test/export_test.exs`, `assert length(per_id) == 26` becomes `27` and
  `assert length(remaining) == length(tests) - 25` becomes `- 26`; in `test/check_selection_test.exs`,
  `assert length(selection.skipped) == 25` becomes `26`. Exactly these three cardinality literals, which a 27th
  per-ID consumer makes false; every identity, equality, partition and limit assertion stays unchanged;

````

### Change 4

Before:

````text
- [ ] Every existing consumer and assertion is unchanged; `test/export_test.exs` equality assertions hold.
````

After:

````text
- [ ] Every existing consumer and assertion is unchanged except the three count literals of amendment 1;
      `test/export_test.exs` equality assertions hold.
````
