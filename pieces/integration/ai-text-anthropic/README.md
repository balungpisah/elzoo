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
the raw body, then **halts every response**. One Elzoo error step halts a
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
  encodes thinking or `output_config.effort` from the model's metadata).
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
  live behaviour, cache hits or savings, output quality, latency or rate limits.
  A periodic live check with a capped budget is a later owner decision.
- **Type/contract check.** Every captured request is validated with `jsv` against
  `test/fixtures/anthropic/messages-request.schema.json`, hand-derived from named
  sections of Anthropic's documentation (fetched 2026-11-09: Messages API
  reference "Create a Message" and its domain types; "Prompt caching";
  "Versions"; "Migrating to API version 2026-10-21"), plus method, path, the
  pinned version header, the injected key and the absence of sampling fields. No
  official machine-readable specification was found; conformance beyond the
  documented examples is not claimed. The schema caught `req_llm`'s object
  operation sending the beta `output_format` member, which is why structured
  output uses `output_config.format`.
- **Tests** (`test/elzoo/ai_text_anthropic_test.exs`): the interface's
  conformance kit; usage and cache scenarios (cold write, warm read, mixed TTL,
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
