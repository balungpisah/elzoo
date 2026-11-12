# ELZ-111 — Add a checked example to core/port

- Phase: example and evidence of a ready Piece. The Contract does not change.
- Catalogue IDs: core/port (existing Contract unchanged).
- Dependencies: none

## Outcome

A developer who copies `core/port` gets one example file that shows the public
calls of the Piece. One test of the Piece evaluates that file, so the hosted
check fails when the example becomes wrong.

## Lane

- `pieces/core/port/` only.
- Index files, in the last commit: your row in `entries` of
  `docs/plans/release-plan.json`, and the generated files.
- No other shared path. If you need one, stop and comment on this issue.

## Work

1. Add `pieces/core/port/examples/elzoo/port.exs`.
   - Line 1 is `# SPDX-License-Identifier: Apache-2.0`.
   - The file uses only the public functions of this Piece and of its
     declared dependencies. It does no I/O and prints nothing.
   - The last expression is a map with one named key for each case below. The
     test reads that map.
   - Keep the file name. A copied consumer gets the examples of all Pieces in
     one `examples/elzoo/` directory, so each name must be unique.
   - Cases for `Elzoo.Port.compatible/2`:
     - an output and an input with equal schema ID and version: `{:ok, true}`;
     - an input used as the source: `{:error, :direction_mismatch}`;
     - a different `schema_id`: `{:error, :schema_mismatch}`;
     - a different `schema_version`: `{:error, :version_mismatch}`;
     - a source map with a fifth key: `{:error, {:source, :invalid_shape}}`.
2. Add the file to `files` in `pieces/core/port/piece.json`. `mix check` refuses a
   bundle file that the manifest does not list. Change no other field of
   `piece.json`.
3. Add one test to `pieces/core/port/test/elzoo/port_test.exs`. It evaluates the example
   with `Code.eval_file(Path.expand("../../examples/elzoo/port.exs", __DIR__))`
   and asserts the exact value of each key. This relative path is also correct
   in a copied consumer, because the copy keeps `test/` and `examples/` side by
   side. Do not change or remove an existing test or assertion.
4. Add one sentence to `pieces/core/port/README.md` that names the example file
   and the test that evaluates it. Change no other sentence.
5. Last commit, index files. `piece.json` changed, so set `manifest_sha256` of
   the `core/port` row in `entries` to the SHA-256 of the new bytes of
   `piece.json`. Do not change `job`, `note` or `disposition` of that row.
   `registry/catalogue.json` needs no change. Then run step 3 of the index
   files in `AGENTS.md`.

## Not in scope

No change in `lib/` or `cure/`. No change of the Contract, the limits, the
grounding list or the operations declarations. No new dependency. No new
claim: the example is a finite test scenario, not a proof.

## Acceptance

- `mix test pieces/core/port/test` exits 0.
- `mix check --affected origin/main`, `git diff --check` and
  `python3 scripts/check-roadmap.py` exit 0.
- Negative control: in a scratch copy, change one expected value in the
  example. The new test must fail. Do not commit that change. Record the
  result in the pull request body.
- The diff holds only: the example file, one added line in `files`, the one
  added test, the one README sentence, the one hash, and generated files if
  they change.
