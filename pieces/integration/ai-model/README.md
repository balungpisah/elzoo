# integration/ai-model

Family core of the AI model Pieces: small, pure, provider-neutral data and
validators that every model-type interface (text first; later batch, decision,
embeddings, rerank, image, speech, video) reuses. No I/O, no process, no
configuration, no external dependency (Elixir and OTP only). Apache-2.0.

## Values

- **Model reference** (`Elzoo.AiModel.ModelRef`): `%{provider, model_id,
  wire_surface}`, each nonempty bounded UTF-8 without control characters.
- **Usage** (`Elzoo.AiModel.Usage`): `%{counters, cache_writes, convention,
  source}`. A counter is `%{unit, amount}` with `unit` from the closed set
  `input_uncached_tokens`, `cache_read_tokens`, `output_tokens`,
  `reasoning_tokens`, `images`, `audio_seconds`, `characters`, `search_units`,
  `video_seconds`; `amount` is a non-negative integer or `:unknown`. A cache write
  is `%{ttl, amount}` with `ttl` from `"5m"`, `"1h"`, `"30m"`, `"12h"`, `"24h"`,
  `"provider_default"`. At most one counter per unit and one write per TTL.
  `convention` is `%{input_includes_cached: boolean}`; `source` is
  `:provider_reported` or `:unknown`. An empty write list is a reported zero; a
  write total the provider did not report is a record with amount `:unknown`.
  Prices and cost are not usage.
- **Cache hint** (`Elzoo.AiModel.CacheHint`): `%{tenant, local_key, ttl,
  breakpoints}`; breakpoints are 1 to 4 distinct `:tools`, `:system` or
  `{:message, index}`.
- **Provenance** (`Elzoo.AiModel.Provenance`): `%{model_ref, provider_model,
  response_id | :absent, request_id | :absent, provider_piece}`.
- **Failure classes** (`Elzoo.AiModel.Failure`): `{:refused, reason}` (attested
  not sent, or rejected by the provider before work) and `{:unknown, reason}`
  (may have been processed and charged). Each type interface owns its reason sets.
- **Job** (`Elzoo.AiModel.Job`): `job_ref` `%{provider, provider_job_id,
  submitted_at}` and `job_state` `:pending | :running | :ending | {:ended, counts}
  | :expired | :cancelled | :failed`, counts `%{succeeded, errored, cancelled,
  expired}`.
- **Stream chunk** (`Elzoo.AiModel.StreamChunk`): `%{seq, kind, payload}`, kind
  `:text_delta | :tool_delta | :usage | :finish`. The shape only; streaming is a
  later slice.

Every validator returns `{:ok, value}` or `{:error, reason}` with a fixed atom;
no input is echoed in an error.

## Accounting identity

The provider's input counter is translated by its documented convention:

- `input_includes_cached: false` (Anthropic: `input_tokens` excludes cache reads
  and writes): `input_uncached_tokens = input`.
- `input_includes_cached: true` (OpenAI: input includes cached and written
  tokens): `input_uncached_tokens = input - cache_read - sum(cache_writes)`; a
  negative difference (an inconsistent report) is `:unknown`, never clamped.

`Usage.prompt_input_tokens/1` is `input_uncached_tokens + cache_read_tokens +
sum(cache_writes)` when every component is known, otherwise `:unknown`, never
zero. `Usage.from_provider/3` builds a validated value from raw counters;
`Usage.unknown/1` is the value for a response without usage.

The cache-hint rule: `CacheHint.validate(hint, dispatch_tenant)` refuses a hint
whose tenant differs from the dispatch tenant with `:invalid_request`. A provider
derives any wire cache key from both `tenant` and `local_key`, never accepts a
caller-supplied global wire key, and maps the hint to its documented mechanism or
refuses the request `:unsupported_feature`. The rule only stops a caller from
naming another tenant's hint; it cannot partition a provider's own cache between
tenants that share one credential.

## Grounding and limits

Tests (`test/elzoo/ai_model_test.exs`) check the identity on the documented usage
examples of Anthropic ("Prompt caching", "1-hour cache duration") and OpenAI
("Prompt caching", "Monitor cache performance"), the `:unknown` propagation for
each missing component, the cross-tenant refusal and the validators. Finite
scenarios, not a proof. Telemetry, Config and Control are not applicable: these
are pure values with no ambient configuration, observation or lifecycle.
