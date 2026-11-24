# integration/ai-text-google

The Gemini API `generateContent` provider of `integration/ai-text`
(`Elzoo.AiText.Google`, implementing `Elzoo.AiText.Provider`), with an API key,
through `req_llm` 1.30's Google provider (Apache-2.0; adopted, not copied; no
gateway process). Apache-2.0. A third vendor for `delivery/model-routing`.

## What the Piece owns and what it adopts

`req_llm` resolves the model from `llm_db`, encodes the contents (user parts in
order, each image as `inline_data`, assistant function calls, function
responses), the function declarations, `toolConfig` and `maxOutputTokens`, sets
the `x-goog-api-key` header and owns the transport, through its documented
provider-callback API: `ReqLLM.Providers.Google.prepare_request/4`, its
`encode_body/1`, then `Req.request/1`.

This Piece owns the translation of the neutral request (and its refusals), one
edit of the encoded body, the response decoding from Gemini's documented
format, usage translation, failure mapping and the conformance stubs. The body
edit sets, from values the pure `translate/2` computed:

- each function declaration's **`parametersJsonSchema`** to the caller's
  parameter schema, unchanged, and removes `parameters` (`req_llm`'s
  `parameters` path removes `additionalProperties` and `$schema` at every
  depth; the reference says the two fields are mutually exclusive);
- each `functionCall` and `functionResponse` part's **`id`** to the neutral call
  id, in order (the reference asks for the exact call id in the response;
  `req_llm` drops it). If `req_llm` did not emit exactly one part per neutral
  call and per tool result, nothing is sent (`unknown{transport}` before any
  byte);
- **`systemInstruction`** to one text part per system message;
- for structured output, `generationConfig.responseMimeType:
  "application/json"` and **`responseJsonSchema`**, the caller's schema
  unchanged.

One Elzoo response step, prepended so it runs before every Req and `req_llm`
response step, copies the status, the `retry-after` header (bounded,
printable) and the raw body, then **halts every response**. The body is bounded
while it is received: a Req `into:` function stops the transfer above 4 MiB of
wire bytes, and any response over the bound, whatever its status, is
`unknown{malformed_response}` with its body never kept. One Elzoo error step
halts a transport exception unchanged. So no redirect is followed, no retry
happens and `req_llm`'s error value (which carries the request body) is never
built. Fixed settings: `max_retries: 0` and Req `retry: false`.

## Evidenced model and wire surface

One model: **`gemini-3.8-flash`** on `POST
/v1beta/models/gemini-3.8-flash:generateContent` at
`https://generativelanguage.googleapis.com` (or an HTTPS `base_url` in the
provider term). `llm_db` 2026.11.0 lists it active with image input, tools and
native JSON schema output. Any other model, even one in the host's allowlist,
is refused `invalid_request` in the pure translation, before any credential
read. Adding a model is a later change with its own evidence.

## Needs

- **The Gemini API key**, as the interface's injected credential Need,
  called and shape-checked before `req_llm` is called and passed as `api_key:`;
  it travels only in the `x-goog-api-key` header (never the `key` query
  parameter). `req_llm`'s configuration and environment fallbacks
  (`GOOGLE_API_KEY`) are never reached; a failing Need sends nothing
  (`refused{credentials_unavailable}`). The host wires the Need, for example to
  `integration/secrets`; this Piece does not call it.
- **`config :req_llm, load_dotenv: false`** in every consumer's configuration
  (see "Install configuration").
- Network egress to the Gemini API.
- `plug` is used by this Piece's tests only.

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
a hand-copied consumer that drops the line is not checked. Without the line,
`req_llm` loads a `.env` file from the working directory when it starts under
Mix. The credential invariant holds regardless: this Piece passes only the
injected Need's key and never reads a key from configuration, the environment
or a `.env` file.

## Capabilities and translation

- Features: **tools, structured output, image input**. Sampling, stop
  sequences, reasoning and cache hints are not declared; the interface refuses
  them `unsupported_feature` before translation. `convention:
  input_includes_cached: true`. Declared provider options: none.
- Messages: system messages become `systemInstruction` parts and are accepted
  only before every other message (a later one is refused
  `unsupported_feature`; Gemini has one system instruction ahead of the
  contents). User text and parts (text and images, in order) become `user`
  contents; assistant text and earlier tool calls become `model` contents; a
  tool result becomes a `functionResponse` with the name of the call it answers
  and `response: {"content": text}`, or `{"error": text}` when `is_error` is
  true (the reference: "if the function call failed to execute, the response
  can have an "error" key"). A tool result that answers no earlier call is
  refused `invalid_request` (the function name is required). A final model turn
  is refused `unsupported_feature` (`req_llm` refuses prefill for Gemini 3 and
  later). Consecutive `user` contents are merged by `req_llm`.
- Replayed function calls carry `req_llm`'s `thoughtSignature`: the base64
  encoding of `skip_thought_signature_validator`. The Thought signatures page
  names the bare string for function calls that Gemini did not sign; that the
  API accepts it base64-encoded, as the `byte`-format field is sent, is an
  assumption. The neutral request does not keep Gemini's own signatures.
- Images: `inline_data` with `mime_type` (`image/png`, `image/jpeg`,
  `image/webp`, `image/gif`, all listed in the reference's `Blob.mimeType`) and
  the base64 bytes the interface resolved and checked.
- Tool choice: `auto` `AUTO`, `none` `NONE`, `any` `ANY`, a named tool `ANY`
  with `allowedFunctionNames: [name]`. Tools are declared with a callback that
  always refuses to run; function calls come back as proposals (data).
- Structured output: `responseJsonSchema` unchanged, so the schema may use only
  the keywords the reference lists for it (`$id`, `$defs`, `$ref`, `$anchor`,
  `type`, `format`, `title`, `description`, `enum` of strings and numbers,
  `items`, `prefixItems`, `minItems`, `maxItems`, `minimum`, `maximum`,
  `anyOf`, `oneOf`, `properties`, `additionalProperties`, `required`,
  `propertyOrdering`), and a `$ref` subschema only the listed `$` keywords.
  Every `$ref` must name a root `$defs` entry (`#/$defs/<name>`), and the
  references must have no cycle: the reference unrolls cycles only to a
  limited degree, which is an approximation. Any other schema is refused
  `unsupported_feature`, never rewritten (a `$ref` that does not compile is
  refused `invalid_request` by the interface first). Structured output
  together with tools is refused `unsupported_feature`.

## Usage

From `usageMetadata` (reference fetched 2026-11-24):

| Core value | Field |
| --- | --- |
| input (`input_includes_cached: true`) | `promptTokenCount` ("includes the number of tokens in the cached content") |
| `cache_read_tokens` | `cachedContentTokenCount` |
| `output_tokens` | `candidatesTokenCount + thoughtsTokenCount` |
| `reasoning_tokens` | `thoughtsTokenCount` |

`candidatesTokenCount` does **not** include the thinking tokens: the reference
gives `totalTokenCount` as prompt + tool-use prompt + thoughts + candidates,
and Token counting says response pricing is the sum of output and thinking
tokens. So `:output_tokens` is the sum and `:reasoning_tokens` a part of it, as
in the ready OpenAI provider. A counter not reported is `:unknown` (also the
sum when either part is absent), never zero, although proto3 JSON may omit zero
values. `generateContent` reports no cache write, so `cache_writes` is empty.
`toolUsePromptTokenCount` (built-in tools only, never requested) and
`totalTokenCount` are not used. No usage object gives source `:unknown`.

## Response and failure mapping

A 2xx is decoded only with a `responseId` and exactly one candidate with a
`finishReason`, whose parts are text (thought summaries skipped) or
`functionCall`; or with no candidate and a `promptFeedback.blockReason` (a
blocked prompt). Anything else is `unknown{malformed_response}`.

Finish reasons (Candidate.finishReason, fetched 2026-11-24):

| Gemini | Neutral |
| --- | --- |
| `STOP` | `:stop`, or `:tool_calls` with a function call |
| `MAX_TOKENS` | `:length` |
| `SAFETY`, `PROHIBITED_CONTENT`, `BLOCKLIST`, `SPII`, `IMAGE_SAFETY` | `:refusal` |
| every other reason (`RECITATION`, `LANGUAGE`, `OTHER`, `MALFORMED_FUNCTION_CALL`, `UNEXPECTED_TOOL_CALL`, `TOO_MANY_TOOL_CALLS`, ...) | `{:other, reason}` |

A blocked prompt's `blockReason` is mapped by the same table, with empty
content. Gemini documents no reason named refusal: its filter stops are the
reasons by which the API declines to answer, so they are reported `:refusal`,
and none is reported `:content_filter` (the ready OpenAI provider reports its
filter stop `:content_filter`).

Statuses, from "API errors (generateContent)" fetched 2026-11-24:

| Status | Tag |
| --- | --- |
| 400 `INVALID_ARGUMENT`, `FAILED_PRECONDITION` | `provider_invalid_request` |
| 400 with an `ErrorInfo` of reason `API_KEY_INVALID` (the page's invalid-key example) | `authentication_failed` (corrected row) |
| 401 | `authentication_failed` |
| 403 `PERMISSION_DENIED` | `permission_denied` |
| 404 `NOT_FOUND` | `not_found` |
| 413 | `provider_too_large` |
| 429 `RESOURCE_EXHAUSTED` | `throttled` |
| 503 `UNAVAILABLE` | `overloaded` |
| 504 `DEADLINE_EXCEEDED` | `provider_timeout` |
| every other status (500, 402, 3xx, ...) | `provider_error` |

Transport timeout is `timeout`; other transport failures `transport`. The page
documents 400, 402, 403, 404, 429, 499, 500, 503 and 504; 401 and 413 rest on
the `google.rpc.Code` HTTP mapping (401 `UNAUTHENTICATED`) and are policy
exercised on stubs. 402 (Prepay credit depleted, "don't retry") falls under
"every other status" by the Contract's table.

`retry_after`, for 429 and 503 only: the `Retry-After` header when there is one,
read as delta-seconds (an HTTP-date or another form gives `nil`); else the
`google.rpc.RetryInfo` detail of the error body, whose `retryDelay` is a
protobuf JSON Duration (`"<seconds>[.<1-9 digits>]s"`), rounded up to whole
seconds (`"1.5s"` gives 2). A value over 86,400 seconds or malformed gives
`retry_after: nil`. Under the interface's Contract amendment 1, `throttled` and
`overloaded` are failed/dispatched/retryable and not redispatched by default.

## Grounding and limits

- **Stub evidence only (ELZ-087's rule: no live API spend).** Every scenario
  runs against an in-process function plug; no live call, no real key. The
  stubs show conformance to the documented format as fetched, never live
  behaviour, output quality, latency, safety filtering, rate limits or prices.
- **Type/contract check.** `test/fixtures/google/generate-content-request.schema.json`
  is hand-derived from the Gemini API `generateContent` OpenAPI document
  (`https://aistudio.google.com/api-reference/generate-content.openapi.json`,
  `v1beta`, fetched 2026-11-24, SHA-256
  `a11386534137dfde9430553b9ee63ffc25a2c6e41908e5192cabcb650252773c`). It admits
  only the members this Piece sends; its `$comment` records the choices (the
  path-bound `model`, both `inline_data` spellings). Every captured request
  validates against it; listed deviations are asserted to be rejected.
- **The fetched reference** lists `responseJsonSchema` and marks the JSON-schema
  output field deprecated in favour of `responseFormat`; this Piece sends
  `responseJsonSchema` as its Contract states, and its continued acceptance is
  an upstream assumption.
- **The documented 20 MB request limit** for inline data is not checked
  locally; the host's `image_bounds` must keep the base64 image data under it.
- **Tests** (`test/elzoo/ai_text_google_test.exs`): the interface's conformance
  kit and image scenario; undeclared features refused; a mixed transcript;
  refusals of inexpressible shapes; images of each media type; finish and usage
  mapping; each status, `Retry-After` and `retryDelay` forms, a redirect,
  malformed and oversized bodies, timeout and closed transport, one request
  each; models and provider terms refused before any request; redaction;
  ambient keys never used; fixture provenance; a source audit of this Piece's
  own files.
- **Upstream contracts.** Gemini API semantics as documented on the pages named
  above (named, not proved); `req_llm` 1.30.0 Google encoding and
  provider-callback API; `llm_db` 2026.11.0 model metadata; Req 0.7.5 steps and
  `Req.Request.halt/2`.
- One model, one API surface (`generateContent`), an API key only. Kept open:
  Vertex AI with a service account, streaming, batch, more models, reasoning,
  cache hints, sampling and stop sequences.
- Telemetry `planned`: no Elzoo event; `req_llm` may emit its request start
  event (payload capture off by default). Config `supported` (construction
  only). Control `not_applicable`.
