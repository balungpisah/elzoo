# ELZ-372 — integration/ai-text-openai sends the image parts of a user message as Responses input images and declares image input

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 2; owner answer Q7 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24); added by coordinator decision at publication, 2026-11-24: the plan kept OpenAI image input addable in place, and its one evidenced model takes images)
- Dependencies: ELZ-087, ELZ-364
- Release: V1B
- Output: none. A change in place of the ready Piece `integration/ai-text-openai` (ELZ-087), before the first release, with the same Piece ID (`AGENTS.md` section 4). A request without image parts translates byte for byte as today.
- Change class: Piece-only implementation
- Owned paths: `pieces/integration/ai-text-openai/**`; in `docs/plans/release-plan.json` the `manifest_sha256` and `note` of the `integration/ai-text-openai` row of `entries`; the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `integration/ai-text` or `workflow/agent-loop`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

The same change as ELZ-371 for the OpenAI provider on its one surface (Responses): it declares `:image_input` and translates a user message of parts into input text and input image content, each image a `data:` URL of its bytes. With this task and ELZ-371 both ready providers take images, so `delivery/model-routing` (ELZ-369) has a real choice for an image request among the ready providers. A low-risk change (`AGENTS.md` section 5): the hosted `check-piece` run may be its small-gate evidence, with one light review.

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5` and `deps/req_llm` 1.30.0. Confirm each before you start; if one differs, stop and comment on the issue.

- `Elzoo.AiText.OpenAI` (`lib/elzoo/ai_text/open_ai.ex`): `@models %{"gpt-6.1-terra" => ...}` (line 34); `capabilities/0` (lines 42–53) declares `features: [:tools, :structured_output, :cache_hint, :reasoning]` and `wire_surface: "responses"`; `context/2` (lines 189–210) has the clause `{%{role: :user, text: t}, i} -> ReqLLM.Context.user([part(t, i, targets)])` (line 198) and no `parts` clause; the cache positions accept any `%{role: :user}` message (line 171). README line 48: "Chat Completions is not supplied"; `piece.json` limit (line 40): "Chat Completions, Azure OpenAI, Realtime, images, audio, ... are refused or not supplied".
- `req_llm` 1.30.0 encodes an image content part of the Responses API as `%{"type" => "input_image", "image_url" => "data:#{media_type};base64,#{base64}"}` and adds `"detail"` from the part's metadata `%{detail: d}` (`deps/req_llm/lib/req_llm/providers/openai/responses_api.ex`, lines 1265–1280 and 1352–1358); `ContentPart.image(data, media_type, metadata)` builds the part (`content_part.ex`, lines 99–101).
- The pinned schema `test/fixtures/openai/responses.schema.json` holds `InputImageContent` with `"required": ["type", "detail"]` and `ImageDetail` `low | high | auto | original`, and `InputImageContentParamAutoParam` with `image_url` `maxLength` 20,971,520. So a part without `detail` does not validate against `InputImageContent`.
- `LLMDB` gives `gpt-6.1-terra` the input modalities `[:text, :image, :pdf]` (read at `main` `b9d1c9d5`).
- ai-text after ELZ-364: as stated in ELZ-371's facts (the `:image_input` gate at `lib/elzoo/ai_text.ex` line 220, the image part `%{type: :image, media_type: m, bytes: bytes}` at lines 273–282, the bounds and the `:image_input` scenario).
- Tests: `test/elzoo/ai_text_openai_test.exs` O1 (lines 232–245) runs `Conformance.scenarios/0` against an in-process Req plug and validates each request against the pinned schema; no golden wire test exists. Consumers of the changed functions outside the Piece: `workflow/agent-loop`'s tests call `translate/2` of this provider (lines 773–786, 1285–1286) with text-only requests and must pass unchanged; no lib module outside `integration/ai-text` calls it.

## The Contract change

- `capabilities/0` adds `:image_input` to `features`.
- `translate/2` takes `%{role: :user, parts: parts}`: one user input message with the parts in order, text parts as input text and image parts as input images with `detail: "auto"` (set through the part metadata), so every image validates against `InputImageContent`.
- The pinned schema bounds an input image's `image_url` at 20,971,520 characters. ai-text's largest `max_image_bytes` (5,242,880) gives a data URL of at most 23 + 4 × ⌈5,242,880 / 3⌉ = 6,990,531 characters (the longest prefix, `data:image/jpeg;base64,`, is 23), so no refusal is added for it; the README states that arithmetic.
- A cache breakpoint on a parts message is refused `{:refused, :unsupported_feature}`.
- The task records the documented image limits of OpenAI's images-and-vision guide with its fetch date in the README; pixel dimensions are not checked.

`piece.json` and the README narrow "images" out of the not-supplied list and name the image scenarios.

## Kept open (owner's "no corner" rule)

- *A `detail` other than `auto`* as a declared provider option; *file-ID or URL images*; *documents*; *Chat Completions*.

## Acceptance

1. **Golden, recorded on the base first:** the wire request (method, path, headers other than the key, decoded body) of each O1 scenario; after the change the same.
2. The `:image_input` scenario of `Conformance.image_scenarios/0` passes against the stub; the captured request has one user input message with an input text and an input image whose data URL decodes to the PNG, with `detail: "auto"`, and validates against `InputImageContent` of the pinned schema.
3. Each media type gives its data URL prefix; eight images give eight input images in order.
4. A cache breakpoint on the parts message is `unsupported_feature` with no request at the stub; an image of ai-text's largest `max_image_bytes` (a Config with `max_image_bytes: 5,242,880`) translates and validates against the pinned schema.
5. Negative controls, one at a time, each restored before the final gates: drop `detail` (case 2's schema check fails); declare `:image_input` without translating the parts (case 2 fails).

Run the Piece tests and the small gate, the roadmap and claims checks and the diff check. One light review, the exact-head hosted check and the merge queue are required.

## Limits to state

Stub evidence only (ELZ-087: no live API spend). One model on the Responses surface. No `detail` choice, no file or URL images, no documents, no pixel checks.
