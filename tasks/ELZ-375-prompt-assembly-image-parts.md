# ELZ-375 — workflow/prompt-assembly puts the images of the newest user message into the request as image parts, when the caller asks for image input

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 2; owner answer Q7 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24))
- Dependencies: ELZ-140, ELZ-364
- Release: V1B
- Output: none. A change in place of the ready Piece `workflow/prompt-assembly` (ELZ-140), before the first release, with the same Piece ID (`AGENTS.md` section 4). An input without the new key builds byte for byte today's request.
- Change class: Piece-only implementation
- Owned paths: `pieces/workflow/prompt-assembly/**`; in `docs/plans/release-plan.json` the `manifest_sha256` and `note` of the `workflow/prompt-assembly` row of `entries`; the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `workflow/agent-loop`, `workflow/context-compaction` or `integration/ai-text`), no root test or helper (`test/support/wave7_remember_and_know_helper.exs` stays unchanged and its tests must pass), no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

Today a `:user` history entry is exactly `%{kind, id, text}`, and an image reference is a `:content` or `:tool_result` entry with an `image/` `ref_media_type`, rendered as a marked text block with no link to a person's message. After ELZ-364, `integration/ai-text` takes a user message of parts with image parts by `state/artifact` reference. This task lets a `:user` entry carry the images that the host vouches for as the person's, and, only when the caller asks for image input, renders the images of the **newest** `:user` entry as image parts of that user message. The decision is by the entry's kind and source: a tool's or a notice's image reference (`:content` and `:tool_result`) stays a marked reference block, so it keeps its source and trust marks. The first caller is `workflow/agent-loop` (ELZ-376).

A pure Piece with no I/O; the change decides what goes into a model request. It may use the hosted `check-piece` run as its small-gate evidence and gets one light review (`AGENTS.md` section 5).

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5`. Confirm each before you start; if one differs, stop and comment on the issue.

- `Elzoo.PromptAssembly.build(input, estimate)` (`lib/elzoo/prompt_assembly.ex`, lines 37–49) is the one public function. `@input_keys` (lines 13–24) are exactly `model, max_output_tokens, role_instructions, skill_instructions, memory, history, tools, window, max_request_bytes, max_image_refs`, all required (`exact?/2`, lines 55 and 109–110); a non-map input or an estimate that is not one-arity is `{:error, :invalid_input}` (line 70). README line 11: "`input` is a map with exactly these atom keys". There is no input named `key`.
- Entry shapes (`@entry_keys`, lines 27–33; checks in `fields?/1`, lines 80–89; README lines 30–40): `user: [:kind, :id, :text]` (text may be empty), `assistant: [:kind, :id, :text, :tool_calls]`, `tool_result: [:kind, :id, :tool_use_id, :content, :ref_media_type]`, `content: [:kind, :id, :content, :ref_media_type]`, `record: [:kind, :id, :keep, :record]`; ids are 1..1,024 bytes, unique across memory and history. README lines 86–87: an "unknown key such as `image`, `document` or `parts`" is `:invalid_input`.
- `image_ref?/1` (line 208) matches `%{ref_media_type: "image/" <> _}` on `:content` and `:tool_result` entries; `remove_old_image_refs/2` (lines 196–206) keeps the newest `max_image_refs` (0..256) and turns each older one into the fixed marked text `"[image reference removed]"` (line 35), before the size fit (line 44).
- Rendering (lines 226–246): `:user` is `%{"role" => "user", "text" => text}` (line 226); the request (lines 312–319) has `version`, `model`, `max_output_tokens`, `messages` and, when non-empty, `tools`; `canonical` is `Request.decode(Request.canonical(request), input.max_request_bytes)` of ai-text (lines 324–325), so a request that ai-text refuses is `{:error, {:request, reason}}` (line 332). The drop order (lines 255–263, 351–367) never drops the newest unit.
- ai-text after ELZ-364 (`pieces/integration/ai-text/lib/elzoo/ai_text/request.ex`, lines 13–26, 47–55, 190–270): a user message `{"role": "user", "parts": parts}` has 1..64 parts and at least one image part; a text part is `{"type": "text", "text": t}` (`t` may be empty); an image part is `{"type": "image", "artifact": {"id": id, "version": v}, "media_type": m}` with `id` 1..64 bytes of `[A-Za-z0-9._-]`, `v` 1..2,147,483,647 and `m` one of `image/png`, `image/jpeg`, `image/webp`, `image/gif`; a request holds at most 8 image parts (a ninth is `too_large`).
- Callers of `build/2`, each passing exactly today's ten keys: `workflow/agent-loop` (`pieces/workflow/agent-loop/lib/elzoo/agent_loop.ex`, lines 621–645), `workflow/context-compaction` (`pieces/workflow/context-compaction/lib/elzoo/context_compaction.ex`, lines 129–145, `max_image_refs: 256`; a build error comes back unchanged, line 42) and the root test helper `test/support/wave7_remember_and_know_helper.exs` (lines 1196–1216, used at `test/wave7_remember_and_know_test.exs` lines 573, 867 and 1205). None of them is changed here; each keeps today's behaviour because the new key is optional.
- Tests: `test/elzoo/prompt_assembly_test.exs`; the `deterministic` group asserts one literal canonical JSON (lines 263–264), the golden of a text-only build; the `image_refs` group (lines 329–337) asserts that `:image`, `:document` and `:parts` keys on a `:user` entry or memory item are `{:error, :invalid_input}` and that no output message holds `image`, `document` or `parts`.

## The Contract change

- **Input.** `build/2` takes one optional key `image_input`, a boolean (default `false`). The other ten keys stay required and exact; any other key is still `:invalid_input`.
- **Entry.** A `:user` entry may hold one more key, `images`: a list of 0..8 maps, each exactly `%{artifact_id, version, media_type}` with the ai-text rules above. A `:user` entry with an `images` key when `image_input` is not `true` is `:invalid_input`, before any drop. An `image`, `document` or `parts` key on any entry or memory item stays `:invalid_input`.
- **Rendering, with `image_input: true`.** The newest `:user` entry of the history, when its `images` list is not empty, renders as `%{"role" => "user", "parts" => [%{"type" => "text", "text" => text} | image parts in order]}`. Every other `:user` entry renders as today's text message, and its `images` are left out with no reference kept (images in older turns are kept open). `:content` and `:tool_result` entries render as today, whatever their `ref_media_type`. Image parts do not count against `max_image_refs`, which keeps bounding the reference blocks; the README says so.
- **Unchanged.** An input without `image_input`, or with `image_input: false` and no `images`, gives today's request and canonical bytes; the drop order, the estimate rule and every other error are today's. The estimate function is given the request with its image parts as references; the README says that image tokens are not in a caller's text estimate unless the caller counts them.

`piece.json` and the README state the key, the entry member, the rendering rule and the source rule; the limit "no image part or image input" is narrowed to "image parts only from the newest user entry, by reference".

## Kept open (owner's "no corner" rule)

- *Images in older turns*; *a tool-result image as a marked image part*; *documents*.
- *Image input for `workflow/context-compaction`*: it builds without the key, so a range holding a `:user` entry with `images` is refused `:invalid_input` there (its build error comes back unchanged); a later change of that Piece may drop or keep them.

## Acceptance

1. **Golden:** the `deterministic` literal canonical JSON is unchanged, and the same input with `image_input: false` gives the same bytes.
2. With the key, a history whose newest `:user` entry holds two images gives that message as one text part and two image parts in order, and the canonical bytes decode through ai-text's `Request.decode/2`.
3. An older `:user` entry's images are left out (its message is today's text form) while the newest's are parts; a newest `:user` entry with `images: []` is today's text form.
4. `images` without the key, with `image_input: false`, with 9 refs, a ref with an extra key, a bad `artifact_id` (65 bytes, a `/`), version 0 and 2,147,483,648, and `image/svg+xml` are each `:invalid_input` before any drop; 8 refs and each media type of the set are accepted.
5. With the key, a `:tool_result` and a `:content` entry with an `image/` `ref_media_type` in the same history stay marked reference blocks, and `max_image_refs` still bounds them at its edge (the newest `max_image_refs` kept, the next one removed) while the newest user entry's eight image parts are kept.
6. The `image_refs` group's refusals of `image`, `document` and `parts` keys still hold; its assertion that no output message holds `parts` holds without the key.
7. Negative control, restored before the final gates: turn `:tool_result` image references into image parts (case 5 fails).

Run the Piece tests and the small gate (locally, or the hosted `check-piece` run), which runs the ready dependents (`workflow/agent-loop`, `workflow/context-compaction` and theirs) and the root tests that read the index, the roadmap and claims checks and the diff check. One light review, the exact-head hosted check and the merge queue are required.

## Limits to state

The host vouches that a `:user` entry's images are the person's; the Piece checks only their shape. Images are references: their bytes, hashes and sizes are checked by ai-text at admission and dispatch, not here. Only the newest user message's images are sent; image tokens are not in the caller's estimate unless the caller counts them. No images in older turns or in compaction, no documents.
