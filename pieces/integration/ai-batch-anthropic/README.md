# integration/ai-batch-anthropic

The Anthropic Message Batches provider of `integration/ai-batch`
(`Elzoo.AiBatch.Anthropic`, implementing `Elzoo.AiBatch.Provider`): a thin own
Adapter on the pinned Req 0.7.5, because `req_llm` 1.30.0 has no batch client.
Item bodies reuse `integration/ai-text-anthropic` so a batched item means what the
same synchronous call means. Apache-2.0.

## Endpoints (anthropic-version 2026-10-21)

- Create: `POST /v1/messages/batches` with `{"requests": [{"custom_id", "params"}]}`.
- Status: `GET /v1/messages/batches/{id}` (documented idempotent).
- Results: `GET /v1/messages/batches/{id}/results`, a streamed `.jsonl` file, one
  `{custom_id, result}` per line, not in request order.
- Cancel: `POST /v1/messages/batches/{id}/cancel`.

Caps: 100,000 requests and 256,000,000 bytes of create body (the guide's "256 MB"
read as decimal megabytes, the smaller reading).

## Item bodies

For each item: `Elzoo.AiText.Anthropic.translate/2` (the synchronous translation),
then `ReqLLM.Providers.Anthropic.prepare_request/4` with the options the
synchronous call passes (`max_retries: 0`, `anthropic_version`, `retry: false`) and
a fixed placeholder key, then `ReqLLM.Providers.Anthropic.encode_body/1`. The
encoded map becomes `params` after removing `"stream": false` (the batch guide
lists `stream` as unsupported in batches; any other value is refused). Nothing is
sent while preparing; the real key is never used for a body.

**API status and upstream risk.** At req_llm 1.30.0 `prepare_request/4` and
`encode_body/1` are documented `ReqLLM.Provider` callbacks (the README's "Advanced
Req Plugin API" and the "Adding a provider" guide; `COMPATIBILITY.md` protects
documented provider callbacks). The **location** of the encoded body, the
request's `:json` option, is not documented ("intermediate maps ... are not
contracts by themselves"). It is guarded by a drift test that compares item
`params` and headers for a fixed corpus with the pinned snapshot
`test/fixtures/anthropic/req-llm-1.30.0-item-bodies.json` and fails on any change.
The root `mix.exs` declares `{:req_llm, "~> 1.30"}` and `mix.lock` locks 1.30.0,
so a lock update could move it to a later 1.x without a `mix.exs` change; the drift
test is the guard.

**Batch-global headers.** `anthropic-version` is always the pin. The outer
`anthropic-beta` is the sorted union of the items' values, each of which must be
in the allowed set (`interleaved-thinking-2025-05-14`, `prompt-caching-2024-07-31`,
`tools-2024-05-16`, the values the pinned `req_llm` adds for reasoning, prompt
caching and tools). An item whose prepared request carries another beta, another
version or any other provider header is refused `unsupported_feature` before any
request. A beta enabled by one item is sent for the whole batch; that these values
are harmless for items that do not use the feature is an unverified assumption.

## Decoding and failure mapping

- Batch object: `in_progress` → `:running`, `canceling` → `:ending`, `ended` →
  `{:ended, %{succeeded, errored, cancelled, expired}}`; an ended batch still
  counting `processing`, an unknown status or a malformed object is
  `malformed_response`. Anthropic reports no job-level pending, expired, cancelled
  or failed state (such batches end with counts).
- Result lines: `succeeded` → the message decoded by
  `Elzoo.AiText.Anthropic.decode/2` and the interface's completion checks
  (provenance names this Piece and the `message_batches` surface); `errored` with
  `invalid_request_error` → `invalid_request`, other error types →
  `provider_error`; `canceled` → `:cancelled`; `expired` → `:expired`; any other
  line refuses the call `malformed_response`. Usage through
  `Elzoo.AiText.Anthropic.Usage.from_raw/1`; absent fields `:unknown`.
- Statuses on every endpoint by the synchronous provider's documented table (400,
  401, 403, 404, 413, 429 with `retry-after`, 529, 504 or `timeout_error`, 500 and
  others); 404 means an unknown or archived batch or results past retention.
  Transport timeout `timeout`, other transport failures `transport`.
- `orphans` is always `[]` (creation is a single request).
- The create body is prepared once at admission (`prepare/2` returns the exact
  body and `meta`, the outer beta value); `submit/2` sends the staged body
  unchanged and rechecks the staged beta value against the allowed set (sorted,
  deduplicated) before sending, sending nothing otherwise.
- Response bodies are read through a bounded collector (4 MiB; error bodies 64
  KiB); results stream under the interface's page, line and scan bounds and stop
  as soon as the page is complete. Each page re-reads from the start (no
  provider paging).

## Needs

- **The Anthropic API key**, as the interface's injected credential Need, sent
  only as `x-api-key`; configuration and environment are never read.
- **`config :req_llm, load_dotenv: false`** (see "Install configuration"), because
  body construction goes through `req_llm`.
- Network egress to the Anthropic API.
- For tests only: `plug` (function plugs through Req's `:plug` option).

## Install configuration

Merge this line into the consuming application's configuration (for example
`config/config.exs`) before the `req_llm` application starts:

```elixir
config :req_llm, load_dotenv: false
```

The copier merges no configuration, so every consumer adds this line by hand; this
Piece's test asserts only that this section carries the exact line. The credential
invariant holds regardless: only the injected key is sent.

## Grounding and limits

- **Stub evidence only (R5).** Every scenario runs against an in-process function
  plug answering in Anthropic's documented formats; no live call, no real key. No
  claim about turnaround, the batch discount, billing of result types, retention,
  rate limits or live behaviour.
- **Type/contract check.** Every captured create request validates with `jsv`
  against `test/fixtures/anthropic/message-batch-create.schema.json`, hand-derived
  from "Create a Message Batch" (Body: `requests`, `custom_id`, `params`) and "Batch
  processing" (Batch limitations; the FAQ on supported features) fetched
  2026-11-09, with the Messages request members of ELZ-079's hand-derived schema
  (without `stream` and `speed`, `max_tokens` at least 1); plus the outer version
  and exact beta union, the injected key, unique `custom_id` and absent `stream`,
  `speed`, `fallbacks` and sampling fields. Not an official specification.
- **Tests** (`test/elzoo/ai_batch_anthropic_test.exs`), through the interface's
  conformance kit: submit accepted, lost and mapped statuses; beta union and
  refusal; the drift test; body equivalence with the synchronous call over the
  fixed corpus (claimed for that corpus only); body bounds; status sequence and
  errors; cancel acknowledged, lost and refused; streamed results with mixed
  types out of order, absent usage, errored types, malformed messages, unknown,
  duplicate and missing ids, contiguous pages, deep-cursor scan limit and line
  limit; redaction with ambient keys set; the Install configuration line; a source
  audit.
- **Upstream contracts.** Anthropic Message Batches semantics, limits, windows (24
  hours), retention (29 days), billing of result types and ordering as documented
  (named, not proved); `req_llm` 1.30.0 callbacks (Hex checksum
  `1c4b19608aa982de5ea396cc6de3d3738e72480182ba11c184e028a4af305edb`); Req 0.7.5
  options and `into:` streaming.
- Telemetry `planned`; Config `supported` (construction only); Control
  `not_applicable`.
