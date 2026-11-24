# ELZ-371 — integration/ai-text-anthropic sends the image parts of a user message as Messages API image blocks and declares image input

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 2; owner answer Q7 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24))
- Dependencies: ELZ-079, ELZ-364
- Release: V1B
- Output: none. A change in place of the ready Piece `integration/ai-text-anthropic` (ELZ-079), before the first release, with the same Piece ID (`AGENTS.md` section 4). A request without image parts translates byte for byte as today.
- Change class: Piece-only implementation
- Owned paths: `pieces/integration/ai-text-anthropic/**`; in `docs/plans/release-plan.json` the `manifest_sha256` and `note` of the `integration/ai-text-anthropic` row of `entries`; the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `integration/ai-text`, `integration/ai-batch`, `integration/ai-batch-anthropic`, `integration/ai-token-count`, `delivery/provider-stream` or `workflow/agent-loop`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

After ELZ-364, `integration/ai-text` resolves each image part of a user message through the host's artifact Need and hands `translate/2` the message `%{role: :user, parts: parts}` with each image part `%{type: :image, media_type: m, bytes: bytes}`, but only for a provider that declares `:image_input`. This task makes the Anthropic provider declare it and translate such a message into the Messages API's content blocks: text parts as text blocks and image parts as base64 image blocks, in order. Everything else is today's.

The provider holds no I/O beyond its one exchange, and the bytes it sends are already checked by ai-text. A low-risk change (`AGENTS.md` section 5): it may use the hosted `check-piece` run as its small-gate evidence and gets one light review.

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5` and `deps/req_llm` 1.30.0. Confirm each before you start; if one differs, stop and comment on the issue.

- `Elzoo.AiText.Anthropic.capabilities/0` (`lib/elzoo/ai_text/anthropic.ex`, lines 33–44) declares `features: [:tools, :structured_output, :stop_sequences, :cache_hint, :reasoning]`. `model/1` (lines 142–147) accepts any id for which `ReqLLM.model("anthropic:" <> id)` gives an `:anthropic` model; there is no model table in the Piece, and the tests use `claude-sonnet-4-5`. `context/1` (lines 149–173) has the clause `%{role: :user, text: t} -> ReqLLM.Context.user(t)` (line 156) and no clause for a `parts` message; a `rescue` (lines 78–79) turns a raise in `translate/2` into `{:refused, :invalid_request}`. The cache hint marks at most one message position through `anthropic_cache_messages: i` (lines 105–140).
- In `integration/ai-text` (ELZ-364): the gate `images(request) != [] and (:image_input not in features or c.artifacts == nil) -> {:error, :unsupported_feature}` (`lib/elzoo/ai_text.ex`, line 220) runs before `translate/2`; the image part reaches the provider as `%{type: :image, media_type: m, bytes: bytes}` (lines 273–282); text parts stay `%{type: :text, text: t}`; a request holds at most 8 images, each at most `max_image_bytes` (default 5,242,880) and together at most `max_total_image_bytes` (default 20,971,520); media types `image/png`, `image/jpeg`, `image/webp`, `image/gif`. `translate/2` refusals other than `invalid_request | unsupported_feature | too_large` become `invalid_request` (lines 231–239). `Elzoo.AiText.Conformance.image_scenarios/0` holds `:image_input` (one text part and one 1×1 PNG from `image_need/0`), which checks only the completion; the wire bytes are the provider test's (`lib/elzoo/ai_text/conformance.ex`, lines 81–132, 178–206).
- `req_llm` 1.30.0: `ReqLLM.Message.ContentPart.image(data, media_type)` (`deps/req_llm/lib/req_llm/message/content_part.ex`, lines 95–101) and `ReqLLM.Context.user/1` with a list of parts; the Anthropic encoder writes an image part as `%{type: "image", source: %{type: "base64", media_type: media_type, data: base64}}` (`deps/req_llm/lib/req_llm/providers/anthropic/context.ex`, lines 289–304).
- `LLMDB` gives `claude-sonnet-4-5` the input modalities `[:text, :image, :pdf]` (`ReqLLM.model("anthropic:claude-sonnet-4-5")`, read at `main` `b9d1c9d5`).
- The stub tests pass an in-process Req plug through `provider_config: %{plug: plug}` (`test/support/ai_text_anthropic_test_helper.exs`, lines 7–33); A1 runs `Conformance.scenarios/0` and `conforms/2` validates each captured request against `test/fixtures/anthropic/messages-request.schema.json`, whose message content allows only text, tool use and tool result blocks (lines 102–123). No golden wire test exists in this Piece.
- Consumers of the changed functions outside the Piece, each unchanged by this task and each run by the small gate: `integration/ai-batch` builds an `Elzoo.AiText.Config` without `artifacts` (`pieces/integration/ai-batch/lib/elzoo/ai_batch.ex`, lines 174–188) and checks each item with `Elzoo.AiText.check/2` (line 284), so a parts item is refused `unsupported_feature` before `translate/2` even after this change; `integration/ai-batch-anthropic` uses `Elzoo.AiText.Anthropic` as its item provider (`lib/elzoo/ai_batch/anthropic.ex`, lines 31 and 55) and calls `translate/2` in its tests (lines 262, 306, 346) with text-only requests; `integration/ai-token-count` refuses a parts request itself (`lib/elzoo/ai_token_count/anthropic.ex`, lines 27–64) and calls `translate/2` in its test (line 140); `delivery/provider-stream` refuses a parts request itself (`lib/elzoo/provider_stream/request.ex`, lines 18–24) and keeps its own copy of this Piece's status mapping (`protocol.ex`, line 224), which this task does not change; `workflow/agent-loop` calls `translate/2` of both providers in its tests (lines 773, 774, 786, 1285, 1286) with text-only requests. The ai-batch `capabilities` check (`ai_batch.ex`, line 102) accepts `:image_input`, a member of `Elzoo.AiText.Provider.features/0`.

## The Contract change

- `capabilities/0` adds `:image_input` to `features`.
- `translate/2` takes a user message `%{role: :user, parts: parts}`: one user message whose content is the parts in order, each text part a text block and each image part an image block of the bytes with its media type (base64 source), through `ReqLLM.Message.ContentPart.image/2`.
- A request with image parts to a model whose `LLMDB` input modalities lack `:image` is refused `{:refused, :unsupported_feature}` before any byte.
- A cache breakpoint on a parts message is refused `{:refused, :unsupported_feature}` (today's rule refuses what req_llm cannot mark exactly; a breakpoint inside a parts message is kept open).
- The task reads Anthropic's Vision page and records the documented per-request image count and per-image size limits with the fetch date in the README; an image over a documented byte limit is refused `{:refused, :too_large}`, and the README states that pixel dimensions are not checked.
- The schema fixture gains the documented image block, hand-derived from the Messages API reference and the Vision page with the fetch date, as the fixture's other blocks are.

`piece.json` and the README follow: the limit "image and document input ... are refused or not supplied" is narrowed to document input, and the claims name the image scenarios.

## Kept open (owner's "no corner" rule)

- *Documents* (Q7 B) and *URL or file-ID image sources*.
- *A cache breakpoint inside a parts message*; *image input for a model added later*, with its own evidence.

## Acceptance

1. **Golden, recorded on the base first:** before any change, record in the test file the wire request (method, path, headers other than the key, and the decoded JSON body) of a text-only request of each A1 scenario; after the change they are the same.
2. The `:image_input` scenario of `Conformance.image_scenarios/0` passes against the stub with an artifact Need double, and its captured request holds one user message with a text block and an image block whose base64 data decodes to the PNG; the request validates against the extended schema.
3. Each media type of the set gives an image block with that media type; eight images give eight blocks in order. (A ninth image, and an image over ai-text's `max_image_bytes` or total, are refused by ai-text before translation; one case each shows that no request reaches the stub.)
4. A model whose `LLMDB` input modalities lack `:image` (a test model term built through `ReqLLM.model/1`, or the case stated as not testable with the reason) and a cache breakpoint on the parts message are `unsupported_feature`, with no request at the stub.
5. The ready dependents' tests pass unchanged (the small gate runs them).
6. Negative control, restored before the final gates: declare `:image_input` without translating the parts (case 2's wire check fails).

Run the Piece tests and the small gate (locally, or the hosted `check-piece` run), the roadmap and claims checks and the diff check. One light review, the exact-head hosted check and the merge queue are required.

## Limits to state

Stub evidence only (the ELZ-087 rule: no live API spend): conformance to the documented format as fetched, not live behaviour, image token counts or pricing. Image tokens are in the input token counters as the provider reports them; no `:images` counter. No documents, URL sources or pixel checks.
