# ELZ-079 — Specify the AI model family core, the text interface Piece and the Anthropic text provider Piece

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/ai-model (family core; RC-16's output), integration/ai-text (new row: text interface), integration/ai-text-anthropic (new row: Anthropic text provider)
- Dependencies: ELZ-006, ELZ-011, ELZ-023

## Outcome

Deliver three Pieces of the `integration/ai-model` family in one PR:

- **`integration/ai-model`, the family core**: pure, provider-neutral types every model
  type reuses: unit-tagged usage counters (tokens, cache read and write tokens by TTL,
  reasoning tokens, and the non-token units later types need: images, audio seconds,
  characters, search units, video seconds), the per-provider input-token and cache
  convention, provenance, the failure classes, the cache hint, the job reference and job
  state (for batch, image and video), and the streaming chunk shape; validators only, no
  I/O.
- **`integration/ai-text`, the text interface**: request, response and outcome types,
  validation, a typed and validated provider-options slot, the provider behaviour, the
  call path through the ELZ-011 Effect and ELZ-023 intent boundaries with bounded retries
  from the ready `delivery/retry-timeout`, and a provider conformance kit.
- **`integration/ai-text-anthropic`, the first provider**: implements the behaviour for
  the Anthropic Messages API through `req_llm` 1.30.x (Apache-2.0; ADOPT, no copy, no
  gateway process), with stubs conforming to Anthropic's documented format including
  prompt caching.

The OpenAI text provider is the companion task ELZ-087 on the same interface. The
interface is shaped here against both providers' documented conventions (usage,
caching, tool calls, structured output), so ELZ-087 adds a Piece without changing this
Contract.

## Decisions this task carries

- Owner decision (2026-11-09, 23:45 WIB): "Model Adapter evidence: stub only (recorded or
  stubbed provider responses built from the providers' documented formats); no live API
  spend. Both provider types, Anthropic and OpenAI, and their feature variance".
- Owner direction (via main, 2026-11-09): `integration/ai-model` is a family of typed
  interfaces, one per model type, each with many providers; each provider stub conforms
  fully to that provider's documented API, including the prompt-caching strategy (cache
  markers and cache usage fields). Owner's slice order: 1 text (fixes the shared usage,
  failure and prompt-cache types), 2 batch job mode, 3 decision and extraction,
  4 embeddings, 5 rerank, 6 image, 7 speech-to-text and text-to-speech, 8 video,
  9 realtime.
- Owner's model (via main, 2026-11-10): each model type is its own ecosystem: one
  provider-neutral interface Piece per type and one provider Piece per provider that
  implements it, assembled by consumers like any other Elzoo Pieces (`piece.json`
  dependencies, export, consumer tests); a new catalogue entry per Piece is admitted
  under the owner's ai-model decision.
- AI model family design rules (owner-agreed, via main, 2026-11-10):
  R1 caller first: a provider Piece is admitted only with a named caller;
  R2 a provider Piece earns its slot through usage and cache-accounting translation,
  failure mapping (accepted, refused, unknown, timeout) and conformance stubs, and a
  Piece that only re-exports `req_llm` is not admitted;
  R3 no lowest common denominator: each type interface carries a typed, validated
  provider-options slot so provider-specific features stay reachable while neutral calls
  stay portable;
  R4 a small shared family core Piece that all type interfaces depend on;
  R5 stub evidence proves conformance to the pinned documented format only, never
  current live behaviour; each provider Piece records that limit; a periodic live check
  with a capped budget is a later owner decision.
- Main's decisions: `req_llm` 1.30.x is the adopted library where it covers a provider
  (product fact 2), with thin own Adapters only where it does not; Anthropic stubs are
  checked against a schema hand-derived from its documentation (no official
  machine-readable specification was found), and that limit is recorded; the usage type
  records each provider's input-token convention and its cache write and read fields.
- Orchestrator's split, stated for review: the core is the first part of this task, not
  its own task, because (a) its convention and cache fields are only meaningful once a
  provider translation exercises them, (b) one dependency and configuration change
  (class X) instead of two, and (c) the job-state and streaming-chunk types are pure data
  with validator tests now, so later slices consume them without growing a ready
  Contract. The interface ships with one real provider so its exact boundary is
  exercised before it is ready (AGENTS: do not promote without exercising the exact
  boundary); each further provider is its own task and Piece.
- Decision record: `docs/plans/catalogue-dispositions.md#integration-ai-model` (product
  fact 2: "ReqLLM calls Anthropic directly, provider key as a Need, no gateway process";
  OD-G: the model gateway is built as Pieces, not run as a service).

## Admission record

1. **Responsibility and caller.** Core: the shared types and validators. Interface: the
   text Contract, its call path and its conformance kit. Anthropic provider: translation
   of the interface's request to the Messages API through `req_llm`, and of the response,
   usage, cache counters and failures back (R2). Callers (R1): C6 agent delegation
   (Claude as the reasoning model behind delegated work items), C7 scheduled research,
   C9 resale (record); routing (`delivery/model-routing`), metering (`domain/metering`)
   and pricing stay separate entries and consume these types later.
2. **Interface and invariant.**
   - *Core (`integration/ai-model`).* `model_ref{provider, model_id, wire_surface}`;
     `usage{counters, cache_writes, convention, source}` where each counter is
     `{unit, amount}` with amount a non-negative integer or `:unknown` and units drawn
     from a closed set (`input_uncached_tokens`, `cache_read_tokens`, `output_tokens`,
     `reasoning_tokens`, `images`, `audio_seconds`, `characters`, `search_units`,
     `video_seconds`); `cache_writes` is a list of `%{ttl: ttl, amount: non_neg_integer |
     :unknown}` with `ttl` from a closed grammar (`5m`, `1h`, `30m`, `12h`, `24h`,
     `provider_default`), one record per TTL; `convention` records the provider's
     documented input-token rule as `input_includes_cached: boolean` (Anthropic: input
     excludes cache reads and writes; OpenAI: input includes them; the pinned `req_llm`
     source states the same distinction, `lib/req_llm/usage.ex:70-76`); `source` is
     `provider_reported` or `unknown`. The accounting identity: when
     `input_includes_cached` is false, `input_uncached_tokens` is the provider's input
     counter; when true, it is `input_tokens - cache_read_tokens - sum(cache_writes)`;
     where every component is reported, `prompt_input_tokens = input_uncached_tokens +
     cache_read_tokens + sum(cache_writes)`, otherwise each unavailable component and the
     derived total are `:unknown` (never zero). Prices and cost are not part of usage
     (pricing is another entry, and `req_llm`'s catalogue cost estimates are dropped);
     `cache_hint{tenant, local_key, ttl, breakpoints}` where `tenant` must equal the
     dispatch tenant (a mismatch is refused `invalid_request`) and providers derive their
     wire cache key from both values, never accepting a caller-supplied global wire key;
     `provenance{model_ref, provider_model, response_id | :absent, request_id | :absent,
     provider_piece}`; failure classes `refused{reason}` (attested not sent, or rejected
     by the provider before work) and `unknown{reason}` (may have been processed and
     charged); `job_ref{provider, provider_job_id, submitted_at}` and
     `job_state{pending | running | ending | ended{counts} | expired | cancelled |
     failed}`; `stream_chunk{seq, kind: text_delta | tool_delta | usage | finish,
     payload}`. Validators reject unknown units and TTLs, negative amounts, a cache hint
     whose tenant differs from the dispatch tenant, and malformed shapes.
   - *Text interface (`integration/ai-text`).* Inputs: a provider binding (Need:
     provider Piece, credential reference, model allowlist, bounds); a request with
     ordered messages (system, user, assistant, tool results; text content parts in this
     slice), tool declarations (name, description, JSON Schema) and `tool_choice`, an
     optional output JSON Schema, `max_output_tokens`, stop sequences, sampling, a
     reasoning control from a closed set, an optional `cache_hint`, an optional
     `provider_options` value (R3: a typed map that the selected provider Piece declares
     and validates; an option the provider does not declare is refused
     `invalid_request`, never ignored), a dispatch identity (tenant, logical request
     reference, attempt) and a deadline; the ELZ-011 Effect declaration and the ELZ-023
     intent record. Outputs: `completed{content, tool_proposals, structured, finish,
     usage, provenance}` where `finish` is one of `stop | length | tool_calls |
     content_filter | refusal | other{raw}`; `refused{credentials_unavailable |
     invalid_request | unsupported_feature | too_large | authentication_failed |
     permission_denied | throttled | overloaded | not_found}`; `unknown{timeout |
     transport | malformed_response | provider_error}`; each mapped to the ELZ-011
     delivery result: refusals decided locally are not dispatched; `throttled` and
     `overloaded` are provider-reported rejections after the request reached
     transport. The provider documentation may describe them as before generation,
     but that is an unverified upstream assumption, not a no-send attestation. They
     map to `failed/dispatched/retryable` and are not automatically redispatched in
     `delivery/retry-timeout`'s default mode; a later retry needs a provider
     idempotency or final no-effect ground. `unknown` is possibly dispatched and
     not retried by default. Provider behaviour callbacks: `capabilities/0` (features, cache mechanism,
     usage convention, declared provider options), `translate/2`, `call/2` (one HTTP
     exchange), `decode/2`, `classify_failure/1`.
   - *Invariants.* One call sends at most one HTTP request (`req_llm` retries off); the
     credential comes only from the injected Need, never from application config, the OS
     environment or a `.env` file, and never appears in a result, error, inspect value,
     log or event; prompts and outputs never appear in errors or logs; tool proposals are
     data: no Piece executes, resolves or loads a tool, and a proposal whose arguments are
     not valid JSON or do not match the declared schema is returned marked `malformed`,
     never dropped or repaired; a structured output is returned only after validation
     against the requested schema, otherwise `structured: {:invalid, reason}`; a 2xx
     response without a provider response id or a recognized stop reason is
     `unknown{malformed_response}`, never an empty success; a usage counter absent from
     the provider response is `:unknown`, never zero; a cache hint is mapped to the
     provider's documented mechanism or the request is refused `unsupported_feature`,
     never silently dropped; provider-executed tools (OpenAI Responses builtins,
     Anthropic server tools) and image or document inputs are refused
     `unsupported_feature` in this slice. Non-goals: streaming (the chunk type is fixed,
     the mode is a later slice), batch, vision input, provider-executed tools, routing,
     fallback, pricing, metering, conversation storage, agent loops.
3. **Reuse check.** `req_llm` 1.30.0 with `llm_db` 2026.11.0, requirement `~> 1.30`
   (GHSA-6vww-5m28-f26v: WebSocket TLS not verified in 1.9.0 to 1.28.0, fixed in 1.29.0),
   locked exactly. Observations of the pinned 1.30.0 source and of stub probes run
   without network (observations of one version, not guarantees; the builder turns each
   into a test against the pinned version and records the package checksum and the probe
   transcript in the provider's provenance) that the Contract answers:
   - default retries on `:closed`, `:timeout`, `:econnrefused` and 408/429/500/502/503/
     504/529 (`lib/req_llm/step/retry.ex:1-60`); a stubbed timeout produced 4 requests by
     default and 1 with `max_retries: 0`;
   - key lookup: `:api_key` option, then application config, then the OS environment
     (`lib/req_llm/keys.ex:56-67`); the application loads `.env` from the working
     directory at start when `Mix` is loaded unless `load_dotenv: false`
     (`lib/req_llm/application.ex:27-31,189-208`); a missing key raises
     `ReqLLM.Error.Invalid.Parameter` instead of returning an error;
   - the `req_llm` application must be started (registry initialization; a call fails
     without it), so the dependency is not `runtime: false`;
   - tools are not executed by `generate_text`, but execution helpers exist
     (`ReqLLM.Tool.execute/2`, `lib/req_llm/tool.ex:293`;
     `ReqLLM.Context.execute_and_append_tools/3`, `lib/req_llm/context.ex:537`) and
     `ReqLLM.Tool.new!/1` requires a callback (`lib/req_llm/tool.ex:86`): the provider
     declares tools with a refusing callback and a source audit of the Piece's own files
     forbids the helpers;
   - malformed OpenAI Responses tool arguments arrive as the raw string; a 2xx body of
     `{}` returns `{:ok, ...}` with empty text and `id == "unknown"`; an Anthropic
     `generate_object` result violating its schema was returned as `{:ok, ...}`;
   - usage is normalized with zeros plus `usage_reported` flags when the provider omitted
     usage (`lib/req_llm/usage.ex:12-45`); Anthropic cache counters are read with a
     default of 0 (`lib/req_llm/providers/anthropic/response.ex:412-413`); cache writes
     are grouped by TTL (`lib/req_llm/usage/normalize.ex:58,406-440`);
   - the HTTP request-id header is not in the text response's call metadata
     (`lib/req_llm/call_metadata.ex:7-12,108`); `response.id` is the provider's message or
     response id;
   - OpenAI routes to Chat Completions or Responses by the `llm_db` execution contract
     (`lib/req_llm/providers/openai.ex:333-341`); Anthropic sends `anthropic-version`
     `2023-06-01` unless overridden (`lib/req_llm/providers/anthropic.ex:178,382`) and
     supports adaptive thinking (`anthropic.ex:993-1004`);
   - prompt caching: Anthropic `cache_control` markers through `anthropic_prompt_cache`,
     `anthropic_prompt_cache_ttl` and `anthropic_cache_messages`
     (`lib/req_llm/providers/anthropic.ex:88-104,1013-1130`); OpenAI `prompt_cache_key`
     and `prompt_cache_options` (`lib/req_llm/providers/openai.ex:248-252`,
     `lib/req_llm/providers/openai/responses_api.ex:951-952`).
   Dependency closure resolved with the repository's current pins: 10 new packages
   (`req_llm`, `llm_db`, `jsv`, `abnf_parsec`, `texture`, `zoi`, `splode`,
   `server_sent_events`, `websockex`, `dotenvy`; Apache-2.0 or MIT), no locked version
   changed. `jsv` (in that closure) validates structured outputs and the conformance
   schemas. InstructorLite is not adopted. Only the provider Piece lists `req_llm` as a
   provider; the core and the interface have no external provider beyond `jsv` for
   schema validation (or OTP-only validation if the builder avoids it).
4. **Split test.** The core is pure and shared by every type interface (R4); the text
   interface is pure policy plus the Effect call path and changes only when the text
   Contract changes; each provider Piece has its own Needs (its key), its own wire format,
   its own stubs and pin facts, and a consumer copies only the providers it uses. A new
   provider is a new Piece, so a ready interface never grows a required Need (AGENTS
   "Evolving a ready Contract").
5. **Failure and evidence.** Dangerous paths (RC-16 acceptance plus the facts above): a
   silent retry duplicating a charged call; malformed tool arguments executed or
   repaired; unknown usage reported as zero; cached and uncached input tokens added under
   the wrong convention; a cache hint silently dropped or a global cache key; an
   undeclared provider option ignored; rate limiting retried without backoff; a timeout
   after dispatch reported as refused; an unsupported structured output accepted; a
   malformed 2xx treated as an empty answer; a key read from the environment or a `.env`
   file; a prompt in an error or log line. Proofs: none required; outcome tables and the
   usage accounting identity are finite data checked by tests. Type/contract check:
   every outgoing stubbed Anthropic request is captured through `Req.Test` and validated
   (method, path, headers including the pinned `anthropic-version`, JSON body) against a
   JSON Schema hand-derived from named sections of the Messages and prompt-caching
   documentation, recorded with URLs and fetch date (main's decision; conformance beyond
   the documented examples is not claimed). Tests: core validators (units, convention,
   cache-hint tenant equality including a cross-tenant rejection, job state, stream
   chunk) as pure tests, including the accounting identity above on documented Anthropic
   and OpenAI usage examples, with each missing component yielding `:unknown`; interface tests with a test provider for the call path, refusals, retries,
   intent refusal of a second dispatch without reconciliation, and provider-options
   validation; the conformance kit run by the Anthropic provider against
   documented-format stubs: text completion; each finish reason; tool proposal
   well-formed, malformed JSON and schema-invalid; structured output valid and invalid;
   usage reported and omitted; cache cold write (write > 0, read 0), warm read, mixed TTL
   write (5 m and 1 h), below-minimum prompt (both 0, no error), breakpoint overflow
   refused before dispatch; reasoning control mapped and refused where unsupported;
   400, 401, 403, 404, 429 (with and without `Retry-After`), 500 and 529 bodies mapped;
   transport timeout after send `unknown` with exactly one request observed; malformed
   2xx `unknown`; credential, prompt and output absent from results, errors, inspect
   values, logs and events; a `.env` file in the working directory never read.
   Upstream: Anthropic API semantics, `req_llm`'s translation and `llm_db`'s model
   metadata are named, not proved. R5: the provider Piece records that its stubs prove
   conformance to the pinned documented format only, not current live behaviour, cache
   hits or savings.
6. **Composition record.** Piece dependencies: `integration/ai-model` has none;
   `integration/ai-text` depends on `integration/ai-model`, `core/effect`,
   `delivery/effect-intent`, `delivery/retry-timeout` (ready);
   `integration/ai-text-anthropic` depends on `integration/ai-text` and is the only one
   with the `req_llm` provider. Needs: the Anthropic API key as an explicit injected Need
   (configuration reference resolved per call, never read from global config by the
   Piece, never logged), following batch 1's decision while `integration/secrets` is
   deferred; network egress; `config :req_llm, load_dotenv: false` in the repository and
   in every consumer of a `req_llm`-backed provider Piece (a `config/` change).
   Operational applicability for each Piece: core: Telemetry, Config and Control
   `not_applicable` (pure types); interface and provider: Telemetry `planned` (no Elzoo
   event; `req_llm` emits `[:req_llm, :request, ...]` and `[:req_llm, :token_usage]`
   events with payload capture off by default, `guides/telemetry-contract.md`, which
   consumer-installed handlers may see; not `inherited`, because extending the ready
   `runtime/telemetry` allowlist is its own change), Config `supported` for the provider
   binding, model allowlist, deadline, bounds and the pinned API version (construction
   time; no hot reconfiguration), Control `not_applicable` (call-scoped; the deadline is
   the only cancellation and cannot erase a dispatched call, which is reported
   `unknown`). No delivery guarantee.

## Scope

- add `pieces/integration/ai-model/`, `pieces/integration/ai-text/` and
  `pieces/integration/ai-text-anthropic/`, each with README, `piece.json`, tests and (for
  the provider) stub fixtures and the hand-derived schema with their provenance; the
  conformance kit lives in the interface's `lib/` so provider Pieces can run it after
  export; test support stays under each Piece's own `test/`; source audits read only the
  Piece's own listed files;
- add `req_llm` (`~> 1.30`, locked at 1.30.0) and `plug` as a pinned test dependency for
  `Req.Test` (unless already present), record both and the closure with licenses in
  `registry/providers.json`; add `config :req_llm, load_dotenv: false`; this is a
  `mix.exs`/`mix.lock`/`config/` change, so one local full `mix setup && mix check` runs
  at the head (class X rule), sequenced with other workers;
- record the `req_llm` package checksum and the probe transcripts in the provider's
  `piece.json` grounding;
- add the three registry rows with their matching roadmap `entries` rows; RC-16's
  output (`integration/ai-model`) is moved to this task at publication and RC-16 marked
  superseded, as RC-10 and RC-19 were for ELZ-055 and ELZ-054 (main's publication step);
  regenerate `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Core validators and the stated accounting identity pass on documented Anthropic
      and OpenAI usage examples, missing components are `:unknown`, and a cache hint for
      another tenant is refused.
- [ ] The conformance kit's scenarios pass for the Anthropic provider against
      documented-format stubs, and every captured request validates against the
      hand-derived schema, whose sources and limit are recorded.
- [ ] A transport timeout after send is `unknown` with exactly one request observed; no
      `req_llm` retry occurs.
- [ ] Usage counters absent from a response are `:unknown`; a cache hint is mapped or
      refused and an undeclared provider option is refused, never ignored.
- [ ] Tool proposals are never executed (source audit) and malformed ones are marked.
- [ ] No credential, prompt or output appears in results, errors, inspect values, logs or
      events, and no key is read from the environment or a `.env` file, with tests.
- [ ] The three Pieces' tests pass in the exported consumer layout; the interface's
      tests run with a scripted test provider and load no provider dependency. A
      per-ID consumer that copies only the core and the interface is open work in
      ELZ-091.
- [ ] Operational applicability is declared per docs/operational-contracts.md for each
      Piece.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite stub tests over listed scenarios built from Anthropic's documentation; request
conformance against a hand-derived schema (conformance beyond the documented examples is
not claimed); pure tests of the core; upstream contracts of Anthropic, `req_llm` and
`llm_db`; no proof and no live call. No claim that the live provider currently behaves as
documented, that cache hits happen or save money, or about output quality, latency or
rate limits (R5).

## Out of scope

The OpenAI text provider (ELZ-087), streaming mode, batch mode (ELZ-085), vision and
document input, provider-executed tools, other providers, routing and fallback, pricing
and metering, the other model types, agent loops, a periodic live check (a later owner
decision).

## Reference

Decision record `integration/ai-model` (ADOPT; product fact 2, OD-G, owner answer 3);
RC-16 contract and acceptance ("Malformed tool arguments, interrupted stream, unknown
usage, rate limit, timeout and unsupported structured output"); ELZ-025 study (tool
proposals as data; usage source tag, never zero); owner decisions, order, model and
design rules of 2026-11-09 and 2026-11-10; main's model-type research (2026-11-09).

## Open questions (none blocks a builder)

1. Anthropic's pinned `anthropic-version`: `req_llm`'s default `2023-06-01` or the
   current documented version; the builder records the choice and the stubs assert it.
2. Anthropic cache counters: through `req_llm` 1.30.0 a missing
   `cache_read_input_tokens` inside a reported usage object reads as 0; recorded as a
   limit unless the builder finds a supported path to the raw usage map.
3. Conformance kit form: scenario data plus assertion helpers in the interface's `lib/`
   (recommended; exported with the interface) versus a test-only kit copied into each
   provider Piece.
