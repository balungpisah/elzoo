# integration/ai-text-openai

The OpenAI Responses API provider of `integration/ai-text`
(`Elzoo.AiText.OpenAI`, implementing `Elzoo.AiText.Provider`), through `req_llm`
1.30 (Apache-2.0; adopted, not copied; no gateway process). Apache-2.0.

## What the Piece owns and what it adopts

`req_llm` resolves the model from `llm_db` and routes it to a wire surface,
encodes the request body (input items, function tools, `text.format`,
`reasoning`, `prompt_cache_key`, `prompt_cache_options`, content-part
`prompt_cache_breakpoint` markers, `store`), sets the `authorization` header and
owns the transport, through its documented provider-callback API:
`ReqLLM.Providers.OpenAI.prepare_request/4` then `Req.request/1` (the
`generate_text` facade is not used because it hides the raw usage map, the HTTP
status and the request id).

This Piece owns the translation of the neutral request (and its refusals), the
response decoding from OpenAI's documented format, usage and cache-counter
translation, failure mapping and the conformance stubs. One Elzoo response step
is prepended so it runs before every Req and `req_llm` response step: it copies
the status, the `x-request-id` and `retry-after` headers (bounded, printable) and
the raw body, then **halts every response**. One Elzoo error step halts a
transport exception unchanged. So no redirect is followed, no retry happens and
`req_llm`'s error value (which carries the request body) is never built.

Fixed settings: `max_retries: 0` (the controlling `req_llm` retry setting), Req
`retry: false` as defence in depth, and `store: false` (the Responses API stores
responses by default; this Piece never chains responses, so nothing is retained
provider-side on its behalf).

## Evidenced model and wire surface

One model: **`gpt-6.1-terra`** on the **Responses** surface (`POST
/v1/responses`). `llm_db` 2026.11.0 routes it there and lists its reasoning effort
values; it is a GPT-5.6-or-later model, so the pinned document's
`prompt_cache_options` and explicit breakpoints express the neutral cache hint
exactly. Any other model, even one in the host's allowlist, is refused
`invalid_request` in the pure translation (before any credential read), and the
`req_llm` route is asserted on every call to still be the Responses surface.
Chat Completions is not supplied; adding a model or surface is a later change
with its own evidence.

## Needs

- **The OpenAI API key**, as the interface's injected credential Need (a
  zero-arity function returning `{:ok, key}`), called and shape-checked before
  `req_llm` is called and always passed as `api_key:`. `req_llm`'s application
  configuration, OS-environment and OAuth-file fallbacks are never reached; a
  failing Need sends nothing (`refused{credentials_unavailable}`).
- **`config :req_llm, load_dotenv: false`** in every consumer's configuration
  (see "Install configuration"). The `req_llm` application must be started (it
  initializes the provider registry), so it is not `runtime: false`.
- Network egress to the OpenAI API.
- `plug` is used by this Piece's tests only (Req.Test-style function plugs); the
  exporter lists it as an ordinary provider of this Piece.

## Install configuration

Merge this line into the consuming application's configuration (for example
`config/config.exs`) before the `req_llm` application starts:

```elixir
config :req_llm, load_dotenv: false
```

The copier (`mix elzoo.take`) merges no configuration: it copies source and writes
dependency instructions only, so every consumer adds this line by hand. The
copied-consumer test harness does not prove a consumer's configuration either;
this Piece's test asserts only that this section carries the exact line. Without
the line, `req_llm` loads a `.env` file from the working directory when it starts
under Mix. The credential invariant holds regardless: this Piece passes only the
injected Need's key as `api_key:` and never reads a key from configuration, the
environment or a `.env` file.

## Capabilities and translation

- Features: tools, structured output, cache hint, reasoning (`low`, `medium`,
  `high`, `max` sent as `reasoning.effort`; a request without reasoning sends
  `reasoning.effort: "none"` explicitly, because the model's default is
  `medium`). **Sampling and stop sequences are not declared**: `req_llm`'s
  Responses encoder drops sampling silently for this model, and the pinned
  `CreateResponse` has no stop member; a request that sets either is refused
  `unsupported_feature` at admission. Declared provider options: none (the cache
  key and cache options are derived from the neutral hint, never caller-supplied).
- Structured output uses `text.format` (`json_schema`, `strict: false`) with the
  caller's schema unchanged; the interface validates the returned text.
  Structured output together with tools is refused `unsupported_feature`.
- Messages: system and user text become `input_text` input items; assistant text
  and earlier tool calls are replayed as output and `function_call` items; a tool
  result becomes `function_call_output`. **A tool result with `is_error: true` is
  refused `unsupported_feature`**: `function_call_output` has no error member in
  the pinned schema, and the flag is never dropped.
- Tool choice: `auto` and `none` as is, `any` as `required`, a named tool as
  `{"type": "function", "name": ...}`. Tools are declared to `req_llm` with a
  callback that always refuses to run; `function_call` items come back as
  proposals (data), their `arguments` string passed on raw for the interface to
  mark malformed. Provider-executed tools cannot be requested; a provider-executed
  tool item in a response is `unknown{malformed_response}`.

### Cache hint

- Wire key: `prompt_cache_key` = `"ez1."` + unpadded base64url SHA-256 of the
  32-bit length-framed tenant and local key (47 bytes). The preimage is
  unambiguous and SHA-256 is a collision-resistant derivation; the tenant and
  key text never reach OpenAI. A hint whose tenant differs from the Config tenant
  is refused by the interface (`invalid_request`).
- Options: `prompt_cache_options: {"mode": "explicit", "ttl": ttl}` with TTL
  `30m` or `12h`; any other TTL is refused `unsupported_feature`.
- Breakpoints: `prompt_cache_breakpoint: {"mode": "explicit"}` on exactly the
  addressed parts. `:system` needs exactly one system message; `{:message, i}`
  indexes the **non-system** messages in order and must name a user message.
  `:tools`, a missing or ambiguous system message, or an assistant or tool-result
  target is refused `unsupported_feature`; an index beyond the non-system
  messages `invalid_request`. All before any request or credential read.
- Without a hint: no key, no options, no markers. OpenAI's default implicit
  prefix caching then applies, **scoped by OpenAI to the organization or project,
  not to the Elzoo tenant**: tenants sharing one OpenAI credential may share that
  cache. Where isolation matters, configure one credential or project per tenant.

## Usage and cache counters

Each counter is tied to a named field of the pinned `ResponseUsage`
(`input_includes_cached: true`: OpenAI's input tokens include cached and written
tokens):

| Core value | Pinned field |
| --- | --- |
| input | `usage.input_tokens` |
| `cache_read_tokens` | `usage.input_tokens_details.cached_tokens` |
| cache write `30m` / `12h` | `usage.input_tokens_details.cache_write_tokens_details.ttl_30m_tokens` / `ttl_12h_tokens` |
| cache write `provider_default` | `usage.input_tokens_details.cache_write_tokens` (no breakdown given) |
| `output_tokens` | `usage.output_tokens` |
| `reasoning_tokens` | `usage.output_tokens_details.reasoning_tokens` |

`input_uncached_tokens = input − cached − Σwrites` (the core's identity); a
negative difference is `:unknown`. When the total and the breakdown disagree, or
a breakdown lacks one TTL field without a matching total, the writes are one
`provider_default` record of `:unknown` (never counted twice, never a partial
sum). An absent field is `:unknown`, never zero; no usage object gives source
`:unknown`. `total_tokens` is not used.

## Response and failure mapping

A 2xx is decoded only as a `response` object with an `id`, a `status` and an
`output` list of `message` (`output_text`, `refusal`), `function_call` or
`reasoning` items; anything else is `unknown{malformed_response}`. Finish:
`completed` → `refusal` if a refusal part is present, else `tool_calls` if a
function call is present, else `stop`; `incomplete` with `max_output_tokens` →
`length`, `content_filter` → `content_filter`, another reason → `{:other,
reason}`; `cancelled`, `queued`, `in_progress` → `{:other, status}`; `failed` →
`unknown{provider_error}`.

Statuses: 400 `provider_invalid_request`; 401 `authentication_failed`; 403
`permission_denied`; 404 `not_found`; 413 `provider_too_large`; 429 `throttled`;
503 `overloaded` (each with `retry-after` seconds when present); 504
`provider_timeout`; 500, 502, other statuses and 3xx `provider_error`; transport
timeout `timeout`; other transport failures `transport`. The pinned `POST
/responses` declares only 200, 400, 404, 429 and 503: the other statuses, and 503
meaning overload, are upstream assumptions and policy exercised on stubs. Under
Contract amendment 1 of the interface, `throttled` and `overloaded` are
failed/dispatched/retryable and not redispatched by default.

## Grounding and limits

- **Stub evidence only (R5).** Every scenario runs against an in-process function
  plug; no live call, no real key. The stubs prove conformance to the pinned
  documented format only, never current live behaviour, cache hits or savings,
  output quality, latency or rate limits.
- **Type/contract check.** `test/fixtures/openai/responses.schema.json` is a
  mechanical extract of the official OpenAI OpenAPI document
  (`openai/openai-openapi` `openapi.json`, commit
  `59f5565459caae84f43c49a738248cf2b268a70f`, fetched 2026-11-09, source SHA-256
  `287f2cbf81b668735c56853b5e2ec40048c8912bead00ac8118190fae9716392`, MIT,
  Copyright (c) OpenAI): the closure of `CreateResponse`, `Response` and
  `ErrorResponse`, references rewritten to `$defs`, the annotation keys
  `description`, `example`, `discriminator` and `x-*` removed, and every `oneOf`
  renamed `anyOf` (fixture SHA-256
  `a0e396861dfbf1472aeccfa132c5bfcb6fa016d9b00d7dc35ad14333efe41e80`). The
  rename is a recorded weakening: the document's `oneOf` branches overlap (for
  example `InputItem` accepts a role/content message as both `EasyInputMessage`
  and `Item`) and OpenAPI tooling picks a branch by discriminator, so strict
  JSON Schema exclusivity rejects even the document's minimal request shape. A
  value must still satisfy at least one documented branch; exclusivity is not
  checked. Every
  captured request validates as `CreateResponse`, every documented-format stub as
  `Response` or `ErrorResponse`; the malformed and partial-usage fixtures are
  negative controls that the schema rejects.
- **Tests** (`test/elzoo/ai_text_openai_test.exs`): the interface's conformance
  kit; usage and cache scenarios; cache-key vectors; cache-hint mapping and
  refusals; reasoning, sampling, stop, model and tool-result refusals; structured
  output and tool choice; finish and status mapping; error statuses and a
  redirect with one request each; timeout with one request; malformed 2xx;
  redaction in results, inspect, owner state, debug logs and `req_llm`
  telemetry; ambient keys never used; a source audit of this Piece's own files.
- **Upstream contracts.** OpenAI Responses API semantics as documented in the
  pinned document (named, not proved); `req_llm` 1.30.0 encoding, routing and
  provider-callback API; `llm_db` 2026.11.0 model metadata; Req 0.7.5 steps and
  `Req.Request.halt/2`.
- **Observations of the pinned version** (probe transcript in the task work
  record): given `max_tokens`, `req_llm` logs a rename warning for reasoning
  models, so this Piece passes `max_completion_tokens`, which it encodes as
  `max_output_tokens`.
- Telemetry `planned`: no Elzoo event; `req_llm` may emit its request start
  event (payload capture off by default). Config `supported` (construction only).
  Control `not_applicable`.
