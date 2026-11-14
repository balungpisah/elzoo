# ELZ-200 — The kept preview of a bounded tool result is a copy, not a part of the whole result

- Dependencies: ELZ-139
- Output: none. A repair inside the ready Piece `workflow/tool-result-limit`; Contract unchanged, the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/tool-result-limit/lib/**` and `pieces/workflow/tool-result-limit/test/**` only. No `piece.json`, no README, no index file.

The automated review of pull request #304 found that the preview of a
result over the bound is a sub-binary of the whole result. A caller that
keeps the pending value therefore keeps the whole result in memory,
although the README says that the pending value holds "never content
beyond the preview".

Facts checked on `main` (confirm each when you start):

- `preview/2` (`lib/elzoo/tool_result_limit.ex`, about 92 to 93) returns
  the text itself when it fits, else `binary_part(text, 0, boundary)`.
- `pending/7` (about 106 to 118) puts that preview into the marked map
  as `"content"` and returns it. `UntrustedContent.decode/1` and
  `encode/1` do not copy it.
- On the BEAM a part of a large binary refers to the whole binary; the
  whole stays alive while the part does. This is known behaviour of the
  runtime, not shown by a test of this Piece today.

## Task

The preview that `preview/2` cuts from a longer text is copied
(`:binary.copy/1`), so that the pending value refers to no byte beyond
the preview. A text that fits is returned as it is. Change nothing else:
the bytes of the preview, the boundary rule, the fields and every result
stay. Contract unchanged.

## Acceptance

- **`preview_is_a_copy`** (new assertions inside the existing test
  `over_bound_reference_and_preview`, so the test claim of `piece.json`
  stays true as it is): for a text result of 1,048,576 bytes that is
  over the bound, `decide/3` gives `{:store, pending, payload}` and
  `:binary.referenced_byte_size/1` of the preview in `pending` equals
  its `byte_size/1`; the same for a preview whose cut goes back to a
  code point boundary.
- Every existing assertion of the Piece passes unchanged; the preview
  bytes of `over_bound_reference_and_preview` are equal to those before.
- Negative control, by a temporary edit that is reverted: without the
  copy the referenced size is the size of the whole result and the test
  fails.
- `mix test pieces/workflow/tool-result-limit/test`, then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The small gate also runs the ready Pieces
  that depend on this one.
- One independent review, risk low.

## Not in scope

The payload that goes to the store, the bounded value after `settle/3`,
`workflow/agent-loop`, `workflow/skill`, and any other Piece.
