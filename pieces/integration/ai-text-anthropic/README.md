# integration/ai-text-anthropic

The Anthropic Messages API provider of `integration/ai-text`
(`Elzoo.AiText.Anthropic`, implementing `Elzoo.AiText.Provider`), through
`req_llm` 1.30 (Apache-2.0; adopted, not copied; no gateway process). Apache-2.0.

## What the Piece owns and what it adopts

`req_llm` resolves the model from `llm_db`, encodes the request body (messages,
tools, `cache_control` markers, thinking, `output_config`), sets the
`x-api-key` and `anthropic-version` headers and owns the transport, through its
documented provider-callback API: `ReqLLM.Providers.Anthropic.prepare_request/4`
then `Req.request/1` ("Advanced Req Plugin API"; the `generate_text` facade is
not used because it hides the raw usage map, the HTTP status and the request id).

This Piece owns the translation of the neutral request (and its refusals), the
response decoding from Anthropic's documented format, usage and cache-counter
translation, failure mapping and the conformance stubs. One Elzoo response step
is prepended so it runs before every Req and `req_llm` response step: it copies
the status, the `request-id` and `retry-after` headers (bounded, printable) and
the raw body, then **halts every response**. A Req `into:` collector retains at
most 4 MiB of wire body bytes (after HTTP framing), stops before appending an
overflowing receive chunk, and discards an oversized body. The accumulator and
the current chunk may coexist; this is not a bound on BEAM heap, TLS or kernel
buffers. Content-encoded bodies stay encoded, as with the previous raw capture.
Oversized successes remain malformed; oversized errors retain their existing
status fallback and retry metadata. One Elzoo error step halts a
transport exception unchanged. So no redirect is followed, no retry happens and
`req_llm`'s error value (which carries the request body) is never built.

Fixed settings: `anthropic-version: 2026-10-21` (Anthropic's "Versions" page
recommends the latest version; "Migrating to API version 2026-10-21" records
that Messages requests with `temperature`, `top_p` or `top_k` receive 400),
`max_retries: 0` (the controlling `req_llm` retry setting) and Req `retry: false`
as defence in depth. `req_llm` accepts the version only as a header override (its
default is `2023-06-01`); no native support for the newer version is claimed.

## Needs

- **The Anthropic API key**, as the interface's injected credential Need (a
  zero-arity function returning `{:ok, key}`), called and shape-checked before
  `req_llm` is called and always passed as `api_key:`. `req_llm`'s application
  configuration and OS-environment fallbacks are never reached; a failing Need
  sends nothing (`refused{credentials_unavailable}`).
- **`config :req_llm, load_dotenv: false`** in every consumer's configuration
  (see "Install configuration"): otherwise `req_llm` loads a `.env` file from the
  working directory when its application starts under Mix. The `req_llm` application must be started (it
  initializes the provider registry), so it is not `runtime: false`.
- Network egress to the Anthropic API.
- For tests only: `plug` (Req.Test-style function plugs). The repository keeps it
  test-only; the exporter lists it as an ordinary provider of this Piece.

## Install configuration

This Piece declares the line below in its manifest field `install_configuration`
(`piece.json`). The exporter (`mix elzoo.take`) writes it, with its reason, into
the generated install file `.elzoo/install/<key>.md` under "Configuration".
Merge it into the consuming application's configuration (for example
`config/config.exs`) before the `req_llm` application starts:

```elixir
config :req_llm, load_dotenv: false
```

The copier (`mix elzoo.take`) merges no configuration: every consumer merges
this line itself. This repository's copied-consumer harness writes the line into
the aggregate copied consumer and checks that the value is set before `req_llm`
starts; for any other consumer it does not prove a consumer's configuration, so
a hand-copied consumer that drops the line is not checked. Without the
line, `req_llm` loads a `.env` file from the working directory when it starts
under Mix. The credential invariant holds regardless: this Piece passes only the
injected Need's key as `api_key:` and never reads a key from configuration, the
environment or a `.env` file.

## Capabilities and translation

- Features: tools, structured output, stop sequences, cache hint, reasoning
  (`low`, `medium`, `high`, passed as `req_llm`'s `reasoning_effort`, which
  encodes thinking or `output_config.effort` from the model's metadata), image
  input (see "Image input").
  **Sampling is not declared**: a request that sets it is refused
  `unsupported_feature` at admission, before any credential lookup. Declared
  provider options: none in this slice.
- Structured output uses the documented `output_config.format` (`json_schema`)
  member with the caller's schema unchanged; the returned text is validated by
  the interface. Structured output together with tools is refused
  `unsupported_feature` in this slice.
- Cache hint: `req_llm` marks tools and system together (`anthropic_prompt_cache`)
  and at most one message position (`anthropic_cache_messages`), with TTL `5m`
  or `1h` (`anthropic_prompt_cache_ttl`). The breakpoint set must be exactly
  `system` (plus `tools` when tools are present) and at most one message; any
  other set or TTL is refused `unsupported_feature`, more than four breakpoints
  `invalid_request`, all before any request. Anthropic's cache has no
  caller-visible key; tenants sharing one key share Anthropic's prompt cache, so
  where isolation matters configure one credential per tenant.
- A tool result's `is_error` flag is carried to the wire `tool_result` block
  (through `req_llm`'s message metadata).
- Tools are declared to `req_llm` with a callback that always refuses to run;
  `tool_use` blocks come back as proposals (data). `input` that is not an object
  is passed on as raw text for the interface to mark malformed.

## Image input

`integration/ai-text` resolves each image part of a user message through the
host's artifact Need and checks it (at most 8 images, each at most
`max_image_bytes`, together at most `max_total_image_bytes`, media type
`image/png`, `image/jpeg`, `image/webp` or `image/gif`) before it calls
`translate/2`, and only for a provider that declares `:image_input`, as this one
does. `translate/2` turns the message `%{role: :user, parts: parts}` into one
user message whose content is the parts in order: each text part a text block
and each image part an image block with a base64 source of the bytes and their
media type (`ReqLLM.Message.ContentPart.image/2`). An empty text part, which
ai-text accepts, is dropped by `req_llm` and sends no block (the reference's
text block requires at least one character); a whitespace-only part is sent. A request without image parts
translates as before; the golden test holds the wire request of each
conformance-kit scenario as recorded before this change.

Refusals, all before any byte is sent:

- A model whose `llm_db` input modalities lack `:image` is refused
  `unsupported_feature`. In `llm_db` 2026.11.0, 6 of the 20 Anthropic records
  hold no modalities at all (for example `claude-3-5-haiku-20241022`); they count
  as lacking `:image`. `claude-sonnet-4-5` holds `[:text, :image, :pdf]`. The
  refusal follows `llm_db`'s metadata, not Anthropic's model support: the Vision
  page says vision is available on every model.
- A cache breakpoint on a parts message is refused `unsupported_feature`
  (`req_llm` would mark its last block; a breakpoint inside a parts message is
  kept open). `req_llm` applies the message index to its wire list, in which
  each run of consecutive tool results is one message, so a breakpoint whose
  index names the parts message in either list is refused. A breakpoint on a
  text message of a request with image parts is kept. (For a request with
  tool-result runs, the index on the wire can name a later message than the
  neutral index; that shift exists for text-only requests too and is not
  changed here.)
- An image whose base64 encoding is over the documented per-image limit is
  refused `too_large`.

Documented limits (Anthropic "Vision", "Image limits and costs", "Request
limits", fetched 2026-11-24, https://platform.claude.com/docs/en/build-with-claude/vision):
at most 100 images per API request for models with a 200k-token context window
and 600 for all other models; each image at most 8000x8000 px, with a stricter
per-image dimension limit when a request holds more than 20 images; each image
at most 10 MB base64-encoded on the Claude API (5 MB on Amazon Bedrock); a
request at most 128 MB on the first-party Claude API. This provider reads the
10 MB as 10,000,000 bytes of base64 and refuses an image whose base64 length,
4 x ceil(n / 3) for n bytes, is over it: 7,500,000 bytes is accepted and
7,500,001 refused. ai-text's largest `max_image_bytes` (its upper bound,
5,242,880 bytes) encodes to 6,990,508 bytes of base64, so the refusal cannot
occur through ai-text; it is a check of `translate/2` alone. ai-text's limit of 8
images per request is under the documented count, and the 20-image threshold is
not reached. **Pixel dimensions are not checked**: an image over the documented
dimensions reaches the API, whose answer is mapped as any other.

Image tokens are in the input token counters as the provider reports them; there
is no separate image counter. A model or size refusal comes after ai-text has
read the artifacts through the Need.

## Usage and cache counters

From the raw usage map ("Prompt caching": "Tracking cache performance" and
"1-hour cache duration"): `input_tokens` excludes cache reads and writes
(`input_includes_cached: false`); `cache_read_input_tokens` is the read;
`cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` are
the `5m` and `1h` writes, or `cache_creation_input_tokens` is one
`provider_default` write when no breakdown is given. When the total and the
breakdown disagree, or a breakdown lacks one TTL field and no total is given, the
writes are `:unknown` (never counted twice, never a partial sum).
`output_tokens_details.thinking_tokens` is the reasoning counter when present. An
absent field is `:unknown`, never zero; no usage object gives source `:unknown`.

## Failure mapping (Anthropic "Errors")

400 `provider_invalid_request`; 401 `authentication_failed`; 403
`permission_denied`; 404 `not_found`; 413 `provider_too_large`; 429 `throttled`
(with `retry-after` seconds when present); 529 `overloaded`; 504, or a
`timeout_error` body with another status, `provider_timeout`; 500, other
statuses (402, 409, 3xx) `provider_error`; transport timeout `timeout`; other
transport failures `transport`. A 2xx that is not a `message` with an `id`, a
content list of text, `tool_use` or thinking blocks and a `stop_reason` is
`malformed_response`. Stop reasons: `end_turn` and `stop_sequence` `stop`,
`max_tokens` `length`, `tool_use` `tool_calls`, `refusal` `refusal`, anything
else `{:other, raw}`. Under Contract amendment 1, `throttled` and `overloaded`
are failed/dispatched/retryable and not redispatched by default (see the
interface's documentation for how a caller retries with its own ground).

## Grounding and limits

- **Stub evidence only (R5).** Every scenario runs against an in-process function
  plug that answers in Anthropic's documented formats; no live call, no real key.
  The stubs prove conformance to the pinned documented format only, never current
  live behaviour, cache hits or savings, output quality, latency or rate limits,
  nor image understanding, image token counts or pricing.
  A periodic live check with a capped budget is a later owner decision.
- **Type/contract check.** Every captured request is validated with `jsv` against
  `test/fixtures/anthropic/messages-request.schema.json`, hand-derived from named
  sections of Anthropic's documentation (fetched 2026-11-09: Messages API
  reference "Create a Message" and its domain types; "Prompt caching";
  "Versions"; "Migrating to API version 2026-10-21"; the image block with a
  base64 source from the Messages API reference `ImageBlockParam` and
  `Base64ImageSource` and "Vision", fetched 2026-11-24), plus method, path, the
  pinned version header, the injected key and the absence of sampling fields. No
  official machine-readable specification was found; conformance beyond the
  documented examples is not claimed. The schema caught `req_llm`'s object
  operation sending the beta `output_format` member, which is why structured
  output uses `output_config.format`.
- **Tests** (`test/elzoo/ai_text_anthropic_test.exs`): the interface's
  conformance kit; the golden wire request of each kit scenario, recorded before
  image input; the image scenarios (the kit's `:image_input` with its PNG decoded
  from the wire, each media type, eight images in order, a ninth and oversized
  images refused by ai-text with no request, a model without image input and a
  breakpoint on the parts message refused with no request, the documented size
  limit on both sides through `translate/2`, ai-text's largest image sent);
  usage and cache scenarios (cold write, warm read, mixed TTL,
  below minimum, absent fields, disagreeing totals); cache-hint and reasoning
  translation and refusals before any request; documented error statuses and a
  redirect, one request each; transport timeout with one request; malformed 2xx;
  redaction in results, inspect, owner state, debug logs and `req_llm` telemetry;
  ambient keys (environment, application configuration, a `.env` file across an
  application restart) never used; a source audit of this Piece's own files.
- **Upstream contracts.** Anthropic Messages API, prompt caching, errors and
  versioning semantics as documented (named, not proved); `req_llm` 1.30.0
  translation and provider-callback API (Hex checksum
  `1c4b19608aa982de5ea396cc6de3d3738e72480182ba11c184e028a4af305edb`);
  `llm_db` 2026.11.0 model metadata; Req 0.7.5 response and error steps and
  `Req.Request.halt/2`.
- **Observations of the pinned version** (probe transcripts in the task work
  record and the pinned source): `req_llm` adds `anthropic-beta` headers for tools
  and prompt caching (its `beta_features/2`);
  it adjusts sampling silently (not reachable here) and encodes reasoning from
  model metadata.
- Telemetry `planned`: no Elzoo event. Because every response is halted, the
  `req_llm` response-side events of these calls are not emitted; its request
  start event may be, with payload capture off by default. Config `supported`
  (construction only). Control `not_applicable`.
