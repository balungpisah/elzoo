# integration/ai-text-compatible

An OpenAI-compatible Chat Completions provider of `integration/ai-text`
(`Elzoo.AiText.Compatible`, implementing `Elzoo.AiText.Provider`), for one HTTPS
base URL per endpoint that the host or a tenant gives (a self-hosted or
regional model), through `req_llm` 1.30 (Apache-2.0; adopted, not copied).
Apache-2.0.

Because the base URL may be a tenant's, it is admitted through
`integration/egress-policy` when the endpoint is built, and every call reaches
only the checked addresses through a host transport Need that pins them, as
`integration/webhook-out` does. Each model's features come from a table that
the host declares.

## Endpoint

`Elzoo.AiText.Compatible.endpoint(opts)` builds the `provider_config` term of
`Elzoo.AiText.configure/1`. `opts` is a keyword list with exactly these keys:

| Option | Value |
| --- | --- |
| `base_url` | an `https` URL of 1..2,048 bytes with no userinfo, query or fragment |
| `policy` | an `Elzoo.EgressPolicy.policy/1` value |
| `resolver` | the `integration/egress-policy` resolver Need |
| `transport` | one-arity Need given `%{host, port, addresses}`, returning `{:ok, req_options}` |
| `models` | 1..64 maps `%{id, features}`: `id` of 1..256 bytes of UTF-8 with no control character (no `\p{Cc}`: C0, DEL or C1), unique; `features` a list of members of `[:tools, :structured_output, :stop_sequences, :sampling, :image_input]` |

This Piece checks the shape first: another scheme, userinfo, a query (also an
empty one), a fragment, a URL over 2,048 bytes, a missing, extra or repeated
key, or a bad model table is `{:error, :invalid}` with no resolver call. Then it
calls `Elzoo.EgressPolicy.resolve/3` once: a refusal is `{:error, {:egress,
reason}}` with the policy's reason (`:host` for an IP literal, `:not_allowed`,
`:port`, `:dns_failed`, `:unavailable`, `:non_public_address`, `:malformed`).
On success it returns `{:ok, endpoint}`, which holds the base URL, the checked
host, port and addresses, the transport Need and the model table. The resolver
is not kept. `inspect` of the endpoint shows no Need.

The addresses are fixed for the endpoint's lifetime: they are checked when the
endpoint is built, not per call. A host that needs new addresses builds a new
endpoint and a new Config.

The host also lists each model in the interface Config's `models` allowlist;
the two lists are separate.

## Needs

- **The API key**, as the interface's injected credential Need (a zero-arity
  function returning `{:ok, key}`), passed only as `api_key:` and sent only in
  the `authorization: Bearer` header. This Piece does not call
  `integration/secrets`; the host wires the Need. `req_llm`'s application
  configuration and environment fallbacks for a key are not reached, because a
  key is always passed.
- **The resolver Need** of `integration/egress-policy`, called once by
  `endpoint/1`.
- **The transport Need**: the host's pinning of the checked addresses
  (production `connect_options` or the host's own `finch` pool, or a `Req.Test`
  plug in tests), as in `integration/webhook-out`. The host connects only to the
  given `addresses`, with SNI and the `Host` header set to `host`. This Piece
  checks only that the answer is a keyword list that Req accepts: an answer
  with no connection options (for example `{:ok, []}`) is not pinned, and Req
  then connects through its default pool after its own DNS lookup. The Piece
  cannot detect that; the pinning is the host's.
- **`config :req_llm, load_dotenv: false`** in every consumer's configuration,
  declared in `install_configuration` (`piece.json`), as for
  `integration/ai-text-openai`: without it `req_llm` loads a `.env` file from
  the working directory when it starts under Mix. The copier merges no
  configuration; each consumer merges the line itself.
- `plug` is used by this Piece's tests only.

## What the Piece owns and what it adopts

`req_llm` encodes the Chat Completions body (messages, image parts as `data:`
URLs, function tools, `tool_choice`, `stop`, `temperature`, `top_p`,
`max_tokens`, `response_format`) and sets the `authorization` header, through
its documented provider-callback API: `ReqLLM.Providers.LMStudio.prepare_request(:chat,
...)` with the model `%{provider: :lmstudio, id: id}`, then `Req.request/1`.

The task named `ReqLLM.Providers.VLLM`. This Piece uses `ReqLLM.Providers.LMStudio`
instead, because at 1.30.0 the vLLM provider declares no provider option, so it
refuses `response_format` (both under `provider_options` and as a top-level
option, checked by a probe), and structured output could not be sent. The LM
Studio provider is `req_llm`'s other OpenAI-compatible Chat Completions provider
with the same default encoding (`ReqLLM.Provider.Defaults`), the same `POST
<base_url>/chat/completions` and bearer header, and a declared `response_format`
provider option. Its own additions (`ttl`, `repeat_penalty`, `reasoning_effort`)
are sent only when set, and this Piece never sets them.

This Piece owns the endpoint and its egress decision, the per-model feature
table, the translation of the neutral request (and its refusals), the
connection options, the response decoding from the documented Chat Completions
format, the usage translation, the failure mapping and the stubs.

### Connection options

`call/2` first calls the transport Need with the endpoint's `%{host, port,
addresses}`. A Need that returns an error, raises, throws or exits, or answers
with anything but `{:ok, keyword}`, is `{:transport, :unavailable}` before any
byte; so is an answer that Req refuses as an option. Then it prepares the
request and:

1. drops `req_llm`'s own `finch` option (`Req.Request.drop_options/2`), so the
   transport Need's options are the only connection options (Req refuses
   `connect_options` beside a `finch` option);
2. merges the transport Need's options;
3. merges `retry: false`, `redirect: false` and the interface's receive timeout
   last, and never sets `connect_options` (`Req.merge/2` would replace the
   host's as a whole).

`max_retries: 0` is passed to `req_llm`. One Elzoo response step, prepended so
it runs before every Req and `req_llm` response step, copies the status, the
`x-request-id` and `retry-after` headers (bounded, printable) and the raw body,
then halts every response; one Elzoo error step halts a transport exception
unchanged. So exactly one exchange happens, no redirect is followed and no retry
happens. The body is bounded while it is received to 4 MiB of wire bytes, as in
`integration/ai-text-openai`: the chunk that crosses the bound halts the
transfer and the received body is dropped, so a larger response of any status
(also a 429 or 503) is `unknown{malformed_response}`, never classified by
status.

`call/2` cannot report an attested no-send to the interface: a
`{:transport, :unavailable}` from the transport Need is classified `transport`
(unknown) by `integration/ai-text`, as every transport result is.

## Capabilities and translation

`capabilities/0`: features `[:tools, :structured_output, :stop_sequences,
:sampling, :image_input]` (what this Piece can translate), provider
`"openai-compatible"`, wire surface `"chat_completions"`, no reasoning levels,
no cache TTLs, convention `input_includes_cached: true` and no provider
options. The interface refuses reasoning and a cache hint before this Piece is
called.

`translate(request, endpoint)`, pure, in order:

- a value that is not an endpoint is `invalid_request`;
- a model not in the endpoint's table is `invalid_request`;
- a request that needs a feature the table does not declare for its model is
  `unsupported_feature`: tools, an output schema, image parts, stop sequences or
  sampling;
- a tool result with `is_error: true` is `unsupported_feature`: the Chat
  Completions tool message has no error member, and the flag is never dropped;
- more than 4 stop sequences is `invalid_request`: the reference documents at
  most 4 (the interface allows 16).

Then the body: `max_output_tokens` as `max_tokens`; system and user text as
messages; a user message with parts as its parts in order, each image as an
`image_url` part with a `data:<media type>;base64,<data>` URL; assistant text
and earlier tool calls replayed; a tool result as a `tool` message; tools as
function tools whose callback refuses to run; tool choice `auto`, `none`, `any`
as `required`, a named tool as `{"type": "function", "function": {"name":
...}}`; stop sequences as `stop`; sampling as `temperature` and `top_p`
(floats); an output schema as `response_format` `json_schema` with `strict:
false` and the caller's schema unchanged (the interface validates the reply).

## Response and failure mapping

A 2xx is decoded only as a `chat.completion` object with an `id`, a `model` and
exactly one choice with a `message` and a string `finish_reason`; `content` and
`refusal` are each a string or null, and `tool_calls` are `function` calls with
an `id`, a `name` and an `arguments` string (passed on raw for the interface to
mark malformed). Anything else is `unknown{malformed_response}`. Finish: a
refusal → `refusal` (its text is the content), `stop`, `length`, `tool_calls`,
`content_filter` as named, another reason → `{:other, reason}`.

Statuses, the table of `integration/ai-text-openai`: 400
`provider_invalid_request`; 401 `authentication_failed`; 403
`permission_denied`; 404 `not_found`; 413 `provider_too_large`; 429
`throttled`; 503 `overloaded` (each with a `Retry-After` in seconds when
present, 0..86,400); 504 `provider_timeout`; every other status
`provider_error`; transport timeout `timeout`; other transport failures
`transport`.

## Usage

From the documented `usage` object (`CompletionUsage`), whose
`prompt_tokens_details.cached_tokens` are "cached tokens present in the prompt",
so `input_includes_cached: true`:

| Core value | Field |
| --- | --- |
| input | `usage.prompt_tokens` |
| `cache_read_tokens` | `usage.prompt_tokens_details.cached_tokens` |
| cache write `provider_default` | `usage.prompt_tokens_details.cache_write_tokens` |
| `output_tokens` | `usage.completion_tokens` |
| `reasoning_tokens` | `usage.completion_tokens_details.reasoning_tokens` |

An absent field is `:unknown`, never zero, so `input_uncached_tokens` is
`:unknown` unless the endpoint reports both cache fields. No usage object gives
source `:unknown`. `total_tokens` is not used.

## Grounding and limits

- **Stub evidence only.** Every scenario runs against an in-process function
  plug (or a recording Req adapter) that the transport Need returns, with a
  resolver double; no socket, no live call, no real key. The endpoint's actual
  behaviour is the host's or tenant's: the stubs show conformance to the
  documented Chat Completions shape only. A compatible endpoint may differ from
  it.
- **Type check.** `test/fixtures/openai/chat_completions_request.schema.json`
  is hand-derived from `CreateChatCompletionRequest` of OpenAI's OpenAPI
  document (`openai/openai-openapi` `openapi.json`, commit
  `59f5565459caae84f43c49a738248cf2b268a70f`, fetched 2026-11-24, source
  SHA-256 `287f2cbf81b668735c56853b5e2ec40048c8912bead00ac8118190fae9716392`,
  MIT, Copyright (c) OpenAI), closed to the documented members this Piece may
  send. Every captured request validates against it; listed negative controls
  are rejected by it.
- **Tests** (`test/elzoo/ai_text_compatible_test.exs`): the interface's
  conformance kit and image scenario; per-model feature refusals with no
  request and the declaring model sending; a model outside the table; the
  endpoint's egress reasons and shape refusals with the resolver call count; the
  64/65-model, 2,048/2,049-byte bounds; the transport Need's argument, its
  failures with no request, and the `connect_options` case without `finch`; 4
  stop sequences sent and 5 refused, a tool-result error flag refused, with no
  request; each status, a timeout and malformed bodies with one request each; a
  body over 4 MiB stopped while received for a 200, 400, 429 and 503, with one
  request each; usage fields; redaction. Negative controls under temporary edits: skipping the table's
  feature check sends a request, and keeping `req_llm`'s `finch` option fails
  the `connect_options` case.
- **Upstream.** `req_llm` 1.30.0 Chat Completions encoding through the LM
  Studio provider and its documented provider-callback API; Req 0.7.5 steps,
  `Req.Request.drop_options/2`, `Req.merge/2` option validation and the `:plug`
  and `:adapter` test transports.
- The address pinning is the host's transport Need; the resolver, the policy and
  the model table are the host's. Addresses are checked when the endpoint is
  built, not per call. No successful public connect is shown; the `finch`
  removal is shown by a recording adapter, not through Finch.
- `integration/ai-text` reads the image artifacts before `translate/2`, so a
  per-model refusal of image input comes after those reads.
- The provider name `openai-compatible` is the same for every endpoint, so an
  outcome's provenance does not tell two endpoints apart; a host that routes
  between endpoints names each by its route candidate.
- Not supplied: per-endpoint quirks as declared options, reasoning and cache
  hints per declared model, streaming, a refresh of the checked addresses inside
  one endpoint.
- Telemetry `planned`: no Elzoo event; `req_llm` may emit its request start
  event. Config `supported` (construction only). Control `not_applicable`.
