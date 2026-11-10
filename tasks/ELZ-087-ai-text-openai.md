# ELZ-087 — Specify the OpenAI text provider Piece for the text interface

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/ai-text-openai (new row: OpenAI text provider)
- Dependencies: ELZ-079

## Outcome

Add the OpenAI provider Piece of the text interface (`integration/ai-text`, ELZ-079):
it implements the interface's provider behaviour for OpenAI through `req_llm` 1.30.x
(ADOPT) and carries stubs conforming to OpenAI's documented API, including its prompt
caching, validated against the official OpenAPI document at a recorded commit. No
interface or core change: ELZ-079 shaped both against OpenAI's conventions. Owner
decision (2026-11-09, 23:45 WIB): "stub only ...; no live API spend. Both provider types,
Anthropic and OpenAI, and their feature variance". This task applies the AI model family
design rules R1 to R5 recorded in ELZ-079 (owner-agreed, via main, 2026-11-10).

## Admission record

1. **Responsibility and caller.** Translate the text interface's request to OpenAI and
   the response, usage, cache counters and failures back (R2: usage and cache-accounting
   translation, failure mapping and conformance stubs, not a re-export of `req_llm`).
   Callers (R1): C6 agent delegation and C7 scheduled research where an OpenAI model is
   the chosen model; C9 resale (record).
2. **Interface and invariant.** The ELZ-079 text interface unchanged. Provider-specific
   facts this Piece declares through `capabilities/0` and its typed provider options
   (R3): wire surface per allowed model (Responses API or Chat Completions, as the pinned
   `llm_db` execution contract selects; `lib/req_llm/providers/openai.ex:333-341`; a
   stub probe routed `openai:gpt-4o-mini` to `/v1/responses`); usage convention
   `input_includes_cached: true` (OpenAI input tokens include cached tokens); cache
   mechanism: automatic prefix caching, with typed options `prompt_cache_key` (derived
   by the provider from the interface's `cache_hint{tenant, local_key}`, never one
   global key, as OpenAI's guidance in `req_llm`'s `guides/openai.md:106-112` states),
   `prompt_cache_options` (TTL and mode where the model supports them) and, for models
   that support it, explicit breakpoints; cache usage counters: each counter the
   provider translates is tied to a named field of the pinned OpenAPI response schema
   for the selected surface (cached reads: `usage.input_tokens_details.cached_tokens`
   on Responses, `usage.prompt_tokens_details.cached_tokens` on Chat Completions); a
   cache-write counter (`cache_write_tokens`) is translated only when the pinned schema
   documents it for that surface (the `req_llm` normalizer merely accepts the field if
   present, `lib/req_llm/providers/openai/responses_api.ex:3015-3049`, which is not
   evidence that the surface documents it), and is `:unknown` otherwise; every counter
   absent from a response is `:unknown`; reasoning control mapped to `reasoning.effort` with the model's documented
   allowed values, other values refused; Responses server-side tools (web search, code
   interpreter) refused `unsupported_feature` (they are provider-executed, per
   `guides/openai.md:809,1029`); a tool call whose `arguments` string is not valid JSON
   (`req_llm` passes it through raw, observed in a stub probe) is returned marked
   `malformed`. Invariants: those of ELZ-079 (one request per call, injected key only,
   no credential, prompt or output in errors or logs, proposals inert, absent usage
   `:unknown`, malformed 2xx `unknown`). Non-goals: Azure OpenAI, the OpenAI Realtime,
   image, audio, Decisions and Batch surfaces (other types or modes).
3. **Reuse check.** `req_llm` 1.30.0, shared closure with ELZ-079 (no new package
   expected). Request conformance: the relevant schemas of the official OpenAI OpenAPI
   document, pinned by commit and fetch date in the Piece's provenance, validated with
   `jsv`. Upstream behaviour named, not proved.
4. **Split test.** One provider Piece: own Needs (the OpenAI key), own wire format and
   stubs; a consumer copies it only when it uses OpenAI.
5. **Failure and evidence.** Dangerous paths: cached tokens counted twice (wrong
   convention); a global cache key mixing tenants; malformed tool arguments executed or
   dropped; a server-side tool silently enabled; silent retries; the key from the
   environment. Proofs: none. Type/contract check: every captured request validates
   against the pinned OpenAPI schemas (method, path, headers, body), per wire surface
   used by the allowlist. Tests: the ELZ-079 conformance kit against documented-format
   stubs per wire surface, plus the OpenAI cache scenarios built only from documented
   schema fields (warm read with `cached_tokens`; a cold write only if the pinned schema
   documents `cache_write_tokens` for the surface, otherwise a test that cache writes are
   `:unknown`; below the documented minimum prompt with the cached counter 0; the wire
   cache key derived from the tenant and local key, and a cross-tenant hint refused), the accounting identity under
   `input_includes_cached: true`, `reasoning.effort` mapping and refusal, a refused
   server-side tool, 400, 401, 403, 404, 429 (with and without `Retry-After`) and 500
   bodies mapped, timeout after send `unknown` with exactly one request, credential and
   prompt absence. R5: the Piece records that its stubs prove conformance to the pinned
   documented format only, not current live behaviour, cache hits or savings.
6. **Composition record.** Depends on `integration/ai-text` (and through it the core).
   Needs: the OpenAI API key as an injected Need (never global config, never logged);
   network egress; `config :req_llm, load_dotenv: false` (set by ELZ-079). Telemetry
   `planned`; Config `supported` (binding, model allowlist, deadline, bounds; construction
   time); Control `not_applicable`.

## Scope

- add `pieces/integration/ai-text-openai/` with the provider, README, `piece.json`, tests,
  stub fixtures and the pinned OpenAPI schema extract with its commit and fetch date
  under the Piece's own `test/`;
- no dependency change expected (if one is needed, the class X rule applies);
- add the catalogue row and release-plan entry, regenerate `LEDGER.md` and the roadmap
  views.

## Acceptance

- [ ] The ELZ-079 conformance kit and the OpenAI cache scenarios pass against
      documented-format stubs for every wire surface the allowlist uses, and every
      captured request validates against the pinned OpenAPI schemas.
- [ ] The accounting identity holds under OpenAI's convention; absent counters are
      `:unknown`; every cache counter is tied to a documented schema field; the wire
      cache key is derived from the tenant and local key.
- [ ] Malformed tool arguments are marked, never executed or dropped; server-side tools
      are refused.
- [ ] A timeout after send is `unknown` with exactly one request observed.
- [ ] No credential or prompt appears in results, errors, inspect values, logs or events,
      with a test.
- [ ] The Piece's tests pass in the exported consumer layout.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] `mix check --affected <base>` and the Piece's tests pass.

## Evidence and limits

Finite stub tests built from OpenAI's documented formats; request conformance against
the official OpenAPI document at a recorded commit; upstream contracts of OpenAI,
`req_llm` and `llm_db`; no proof and no live call (R5).

## Out of scope

Azure OpenAI, Realtime, images, audio, Decisions, Batch, streaming mode, routing.

## Reference

ELZ-079 (interface, core and design rules); owner decisions and order of 2026-11-09;
main's model-type research (OpenAI caching section).

## Open questions (none blocks a builder)

1. The model allowlist for the evidence (which OpenAI models, therefore which wire
   surfaces are stubbed); recommended: one Responses-surface model, and Chat Completions
   only if a caller needs a model routed there.
