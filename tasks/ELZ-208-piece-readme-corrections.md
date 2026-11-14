# ELZ-208 — Seven sentences in Piece documents say what the code and the engine do today

- Dependencies: ELZ-171, ELZ-162, ELZ-101, ELZ-155, ELZ-140, ELZ-141, ELZ-142, ELZ-009, ELZ-172, ELZ-193
- Output: none. Corrections of documents of seven ready Pieces; no code, no test and no Contract of a Piece changes, and each Piece ID stays.
- Change class: Piece-only (documents of Pieces; the index rows follow where a `piece.json` changes); small local gate and hosted `check-piece`.
- Allowed implementation path: only the files named in the seven items below, and the index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of the rows of `workflow/agent-loop` and `integration/sql`). No file of `lib/`, `cure/`, `test/` or `examples/`.

The automated reviews of pull requests #385, #355, #339 and #305 left
one finding each on a sentence of a README. A later read found three
more sentences of the same kind: two that describe the run engine as it
was before ELZ-172, and one reference to the documents of another
PostgreSQL version than the one that CI runs. None of them needs code.
This task corrects the seven texts and nothing else.

Each item gives the file, the sentence on `main` at the time of writing,
the corrected sentence, and whether `piece.json` changes. Confirm each
current sentence when you start. If one differs, or if a corrected
sentence is not true of the code at your head, stop and comment on the
issue; do not write a third wording.

## The seven corrections

1. **`pieces/state/recipe-store/README.md`** (quick start, about line
   44). The block publishes `identity` and then deletes it; `delete/3`
   is refused while the version is published (same README, about 63 to
   64; `examples/`, about line 159).

   Now:

       {:ok, :deleted}  = Elzoo.RecipeStore.delete(recipes, caller, identity)

   Corrected:

       {:error, :published} = Elzoo.RecipeStore.delete(recipes, caller, identity)  # refused while published

   `piece.json` does not change (the block is not in it).

2. **`pieces/domain/recipe-config/README.md`** (about 92 to 93).
   `check/2` matches each five-element tuple with the module tag
   (`lib/elzoo/recipe_config.ex`, about 43 to 45) and then reads its
   parts, so a forged tuple of that form can raise. The test covers
   `nil`, a checked payload schema and a two-element tuple.

   Now: "`check/2` with a value not returned by `build/1` is
   `:validation_failed`, without raising."

   Corrected: "`check/2` with a value that has not the form of a
   `build/1` result (for example `nil`, a checked payload schema or a
   tuple of another size) is `:validation_failed`, without raising. A
   forged value of that form is outside the Contract and can raise."

   `piece.json` does not change: its assumption (about line 48) already
   says "forged internals are outside the Contract".

3. **`pieces/delivery/data-stream/README.md`** (about 156 to 157). The
   `cache_creation` exception is stated directly above (about 149 to
   154), but the closing sentence does not exclude it.

   Now: "A stream with an ignored member or event gives exactly the
   frames, usage, finish reason, provenance and terminal of the same
   stream without it."

   Corrected: "Apart from the `cache_creation` exception above, a stream
   with an ignored member or event gives exactly the frames, usage,
   finish reason, provenance and terminal of the same stream without
   it."

   `piece.json` does not change: it has no such closing sentence, and
   its test claim names the exception ("a cache_creation lifetime that
   is not read leaves the group unused").

4. **`pieces/workflow/context-compaction/README.md`** (section
   "`accept(state, input)`", after the list of results, about line 50).
   `accept/2` returns a state only as `{:late, state}`
   (`lib/elzoo/context_compaction.ex`, about 46 to 65); a second
   completed outcome given with the same state gives a second summary.
   The README does not say what the state is worth after the call.

   New sentence: "Only `{:late, state}` gives the state back. After each
   other result of `accept/2` the state is spent: the caller does not
   give it to `accept/2` again. The Piece does not refuse a second
   completed outcome for a spent state; the engine settles an action
   once and sends none."

   `piece.json` does not change.

5. **`pieces/workflow/typed-decision/README.md`** (about 98 to 100).
   Since ELZ-172 the ready `assembly/run-engine` gives a nested finish
   to the parent (its README, about 189 to 195).

   Now: "No engine claim: with the ready `assembly/run-engine`, a nested
   callable outcome does not carry the child finish payload, so a parent
   pattern that needs the value calls `step/2` inside its own step."

   Corrected: "No engine claim: the ready `assembly/run-engine` gives
   the first admitted finish of a nested callable to the parent action
   only when its schema key equals the `result` of the parent's
   `nested_callable` binding, and this Piece tests nothing with the
   engine. A parent pattern can also call `step/2` inside its own step
   and read the finish request."

   `piece.json` does not change: its Limit (about line 14) names only
   the second way, which still holds.

6. **`pieces/workflow/agent-loop/README.md`** (about 238 to 242) and
   **`pieces/workflow/agent-loop/piece.json`** (about line 24). The
   same stale clause on the engine. The step reads a completed outcome
   only under `elzoo.agent-loop.tool-result` version 1
   (`lib/elzoo/agent_loop.ex`, about 356 to 367).

   README now: "... and holds no child result in a nested callable
   outcome (that call gets `[tool result not readable]`)."

   README corrected: "... and gives the first admitted finish of a
   nested callable to the parent action only when its schema key equals
   the `result` of the parent's `nested_callable` binding (a completed
   outcome under another schema than `elzoo.agent-loop.tool-result`
   version 1 gets `[tool result not readable]`)."

   `piece.json` now: "... no engine claim (the ready run engine refuses
   a stopped root finish and gives no result of a nested callable)."

   `piece.json` corrected: "... no engine claim (the ready run engine
   refuses a stopped root finish and gives the finish of a nested
   callable to its parent only under the result schema of the
   binding)."

   `piece.json` changes: the `manifest_sha256` of the row of
   `workflow/agent-loop` follows. Its `contract` sentence, and so the
   `note` of the row, do not change.

7. **`pieces/integration/sql/piece.json`** (about line 67). The
   upstream reference of the server contracts names the documents of
   PostgreSQL 14. CI and the local services run PostgreSQL 16 (the
   image in `.github/workflows/symbolic-check.yml`; AGENTS.md section
   5).

   Now: `"reference": "https://www.postgresql.org/docs/14/transaction-iso.html"`

   Corrected: `"reference": "https://www.postgresql.org/docs/16/transaction-iso.html"`

   Read the page of version 16 and confirm that the claim beside the
   reference still follows from it; record that under `Upstream:`. The
   README of the Piece names no version of these documents and does not
   change. `piece.json` changes: the `manifest_sha256` of the row of
   `integration/sql` follows; its `contract` and `note` do not change.

In-place change of ready Pieces, same Piece IDs; Elzoo is not released.
Change the two index rows in the last commit before the pull request is
opened.

## Acceptance

- The diff changes only the seven texts above, the two `manifest_sha256`
  values, and the generated files of AGENTS.md section 3.
- Each corrected sentence is true of the code at the head: the pull
  request body names, for each of the seven, the file and lines that
  show it (read in code; no new test).
- The tests of the seven Pieces pass unchanged:
  `mix test pieces/state/recipe-store/test`,
  `mix test pieces/domain/recipe-config/test`,
  `mix test pieces/delivery/data-stream/test`,
  `mix test pieces/workflow/context-compaction/test`,
  `mix test pieces/workflow/typed-decision/test`,
  `mix test pieces/workflow/agent-loop/test` and
  `mix test pieces/integration/sql/test`; then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. If a test of a Piece reads one of the
  changed sentences and fails, stop and comment on the issue.
- One independent review, risk low.

## Not in scope

The same stale sentence in `workflow/graph-run` (its own task), the
other clauses of the "No engine claim" paragraphs, the other Pieces that
name the documents of PostgreSQL 17, a refusal of a forged value in
`domain/recipe-config`, a refusal of a spent state in
`workflow/context-compaction`, and every file that is not named above.
