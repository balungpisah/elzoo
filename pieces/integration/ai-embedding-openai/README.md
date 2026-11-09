# integration/ai-embedding-openai

The OpenAI embeddings provider of `integration/ai-embedding`
(`Elzoo.AiEmbedding.OpenAI`, implementing `Elzoo.AiEmbedding.Provider`), through
`req_llm` 1.30 (Apache-2.0; adopted, not copied; no gateway process). Apache-2.0.

## What the Piece owns and what it adopts

`req_llm` resolves the model from `llm_db`, encodes `POST /v1/embeddings`, sets
the bearer `authorization` header and owns the transport, through its documented
provider-callback API: `ReqLLM.Providers.OpenAI.prepare_request(:embedding, ...)`
then `Req.request/1`. The `ReqLLM.embed/3` facade is not used: it hides the HTTP
status, the `x-request-id` header and the raw usage, returns a response with
fewer vectors than inputs as success, and builds an error value that carries the
response body.

This Piece owns the translation of the neutral request (and its refusals), the
response decoding from OpenAI's documented format, usage translation, failure
mapping and the conformance stubs. The interface owns every check of the
returned vectors (count, indices, length, values, served model, norm). One Elzoo
response step is prepended so it runs before every Req and `req_llm` response
step: it copies the status, the `x-request-id` and `retry-after` headers
(bounded, printable) and the raw body, then **halts every response**. One Elzoo
error step halts a transport exception unchanged. So no redirect is followed, no
retry happens and `req_llm`'s decode, usage and error steps never run.

**Retry setting.** `prepare_request(:embedding, ...)` refuses top-level
`max_retries` and `receive_timeout`; `req_llm`'s retry step reads the request's
own `max_retries`, so the Piece passes `req_http_options: [max_retries: 0,
receive_timeout: ms]`. Observed with the pinned version (probes in the task work
record): a stubbed timeout or 500 gave 4 requests without the setting and 1 with
it, with or without the halting steps. Tests check each protection on its own.

## Needs

- **The OpenAI API key**, as the interface's injected credential Need (a
  zero-arity function returning `{:ok, key}`), called and shape-checked before
  `req_llm` is called and always passed as `api_key:`. `req_llm`'s application
  configuration and OS-environment fallbacks are never reached; a failing Need
  sends nothing (`refused{credentials_unavailable}`).
- **`config :req_llm, load_dotenv: false`** in every consumer's configuration
  (see "Install configuration"). The `req_llm` application must be started (it
  initializes the provider registry), so it is not `runtime: false`.
- Network egress to the OpenAI API.
- For tests only: `plug` (Req.Test-style function plugs) and `jsv` (schema
  validation of captured requests and stubs).

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

- Models (OpenAI "Vector embeddings"; `llm_db` 2026.11.0 agrees, checked by a
  test): `text-embedding-3-small`, native 1536, `dimensions` 1..1536;
  `text-embedding-3-large`, native 3072, `dimensions` 1..3072.
  `text-embedding-ada-002` is not declared. An allowlist naming an undeclared
  model is refused at construction.
- The wire request carries `model`, `input` (always an array, so the documented
  response is always a list), `encoding_format: "float"` and `dimensions` only
  when the request has it.
- `input_type`: only `unspecified` is declared (OpenAI has no query or document
  distinction); `query` or `document` is refused `unsupported_feature` at
  admission, before any credential read.
- Declared provider option: `user` (the documented end-user identifier, 1..256
  printable ASCII bytes). Any other key, or an invalid value, is
  `invalid_request`.

## Response decoding, usage and provenance

A 2xx must be the documented `CreateEmbeddingResponse`: `{"object": "list",
"data": [{"object": "embedding", "index", "embedding"}], "model", "usage"}`; any
other shape is `malformed_response`. The items are passed to the interface as
listed; the interface validates and orders them. The served `model` must equal
the requested model (the interface's rule).

Usage: `prompt_tokens` is `input_uncached_tokens` under `input_includes_cached:
false` (no prompt cache is documented for embeddings); `total_tokens`, when
present, must equal it, otherwise the input counter is `:unknown`. Cache reads,
cache writes and output are not reported: `cache_read_tokens` and
`output_tokens` are `:unknown` and the writes are one `provider_default` record
of `:unknown` (never an empty list, which would mean a reported zero), so
`prompt_input_tokens` is `:unknown`. No usage object gives source `:unknown`.

Provenance: `model_ref{provider: "openai", model_id: requested, wire_surface:
"embeddings"}`, `provider_model` the response's `model`, `response_id: :absent`
(embeddings carry no id), `request_id` the `x-request-id` header or `:absent`,
`provider_piece: "integration/ai-embedding-openai"`.

## Failure mapping

The statuses documented for `POST /embeddings` in the pinned OpenAPI document:
400 `provider_invalid_request`; 401 `authentication_failed`; 403
`permission_denied`; 429 `throttled` (with `retry-after` seconds when present);
500 `provider_error`; 503 `overloaded` (with `retry-after` when present). Not
listed for this path and mapped by their HTTP meaning: 404 `not_found`, 413
`provider_too_large`. 529 (the overload status of other providers, not listed
for this path) is `overloaded` by the family rule, like 503. Any other status, 3xx included, is `provider_error`;
transport timeout `timeout`; other transport failures `transport`. Under the
family rule (ELZ-079 amendment 1), `throttled` and `overloaded` are
failed/dispatched/retryable and not redispatched by default.

## Grounding and limits

- **Stub evidence only (R5).** Every scenario runs against an in-process
  function plug answering in OpenAI's documented formats; no live call, no real
  key. The stubs prove conformance to the pinned documented format only, never
  current live behaviour, embedding quality, cost, latency or rate limits.
- **Type/contract check.** Every captured request is validated with `jsv`
  against `CreateEmbeddingRequest`, and every documented-format stub against
  `CreateEmbeddingResponse` or `ErrorResponse`, from
  `test/fixtures/openai/embeddings.schema.json`: an extract of the official
  OpenAI OpenAPI document (repository `openai/openai-openapi`, commit
  `59f5565459caae84f43c49a738248cf2b268a70f`, file `openapi.json` SHA-256
  `287f2cbf81b668735c56853b5e2ec40048c8912bead00ac8118190fae9716392`, fetched
  2026-11-09), copied unchanged except for `$ref` paths, with that repository's
  MIT notice in the file. It is test data, not a runtime provider.
- **Tests** (`test/elzoo/ai_embedding_openai_test.exs`): the interface's
  conformance kit at a requested and the native dimension; usage; translation
  and refusals before any request; documented error statuses, a 529 and a redirect, one
  request each; transport timeout with one request and the retry setting on its
  own; malformed 2xx; redaction in results, inspect, owner state, debug logs and
  `req_llm` telemetry; ambient keys (environment, application configuration, a
  `.env` file across an application restart) never used; a source audit of this
  Piece's own files; the Install configuration line.
- **Upstream contracts.** OpenAI embeddings API as documented (named, not
  proved), including the unit length of its embeddings (the interface verifies
  the norm instead of assuming it); `req_llm` 1.30.0 translation and
  provider-callback API (Hex checksum
  `1c4b19608aa982de5ea396cc6de3d3738e72480182ba11c184e028a4af305edb`); `llm_db`
  2026.11.0 model metadata; Req 0.7.5 response and error steps and
  `Req.Request.halt/2`.
- Telemetry `planned`: no Elzoo event; because every response is halted, the
  `req_llm` response-side events are not emitted. Config `supported`
  (construction only). Control `not_applicable`.
