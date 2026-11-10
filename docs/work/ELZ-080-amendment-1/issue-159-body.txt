# ELZ-080 — Specify the embedding interface Piece and the OpenAI embedding provider Piece

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/ai-embedding (new row: embedding interface), integration/ai-embedding-openai (new row: OpenAI embedding provider)
- Dependencies: ELZ-006, ELZ-011, ELZ-023, ELZ-079

## Outcome

Own the embedding interface Piece of the `integration/ai-model` family and its first
provider Piece, following the owner's model (one provider-neutral interface Piece per type,
one provider Piece per provider, assembled by consumers like any other Pieces): one call
turns a bounded
batch of texts into vectors, each result stating provider, model, dimensions, element
type, normalization and usage with its source, so that stored vectors from different
sources are never compared by accident. OpenAI is the first provider, through `req_llm`
1.30.x (ADOPT). Evidence is stub-only. The owner's order places embeddings fourth (after
text, batch and decision); this body is drafted now because the pgvector store (ELZ-082)
needs it. Owner decision (2026-11-09, 23:45 WIB): "Vector slice: pgvector with OpenAI
embeddings; embeddings are a provider-neutral class so we can add more sources"; owner
decision on evidence: "stub only (recorded or stubbed provider responses built from the
providers' documented formats); no live API spend".

This task applies the AI model family design rules recorded in ELZ-079 (owner-agreed, via
main, 2026-11-10): R1 caller first; R2 a provider Piece earns its slot through usage and
cache-accounting translation, failure mapping and conformance stubs, never a re-export of
`req_llm`; R3 a typed, validated provider-options slot in the interface; R4 the shared
family core (`integration/ai-model`) is a dependency; R5 stub evidence proves conformance
to the pinned documented format only, never current live behaviour, and each provider
Piece records that limit.

## Admission record

1. **Responsibility and caller.** Interface (`integration/ai-embedding`): request,
   result and descriptor types, validation (count, index, length, finiteness, norm),
   the provider behaviour, the Effect and intent call path, typed provider options (R3)
   and a conformance kit. Provider (`integration/ai-embedding-openai`): translation to
   OpenAI through `req_llm` and back, including usage and failure mapping (R2).
   Callers (R1): ELZ-082 (index writes and query embeddings), C7 scoped retrieval.
2. **Interface and invariant.** Inputs: a provider binding (Need: provider, credential
   reference, model allowlist, bounds); a request with `inputs` (1..N texts, each
   bounded in bytes; the whole request is bounded by its command payload: the exact
   UTF-8 bytes of the canonical JSON command payload admitted as the ELZ-023 intent's
   `arguments`, every request member and JSON escaping included, must be 1..65,536
   bytes, the `delivery/effect-intent` argument bound, else `refused{too_large}` before
   any intent, credential read or transport call; this is not an HTTP-body limit, and
   a caller whose inputs do not fit splits them across calls), `dimensions` (optional, provider-supported values
   only), `input_type` (`query | document | unspecified`; mapped where the provider has
   it, refused `unsupported_feature` where the caller requires it and the provider lacks
   it), a dispatch identity and a deadline; the ELZ-011 Effect declaration and the ELZ-023
   intent record. Output: `completed{embeddings: [%{index, vector}], descriptor, usage,
   provenance}` where `descriptor = {provider, model, dimensions, dtype: :float32,
   normalization}` and `normalization` is `unit_l2_verified` (the Adapter checked every
   vector's L2 norm within the interface-wide tolerance `abs(norm_l2(v) - 1) <=
   1.0e-3`, fixed by this Contract and not configurable, so `unit_l2_verified` has one
   meaning in every descriptor) or `none` (a vector outside the
   tolerance completes with `normalization: none`; a store binding that requires unit
   vectors, such as ELZ-082's cosine index, refuses it); `refused{credentials_unavailable
   | invalid_request | unsupported_feature | too_large | authentication_failed |
   permission_denied | throttled | overloaded | not_found}`; `unknown{timeout |
   transport | malformed_response | provider_error}`; each mapped to the ELZ-011 delivery
   result as in ELZ-079. Invariants: after validating that the returned indices are
   exactly `0..length(inputs)-1`, the Adapter sorts by index and emits that validated
   index, so input order is list order; exactly one vector per input, each of
   the declared dimension, finite floats only; a response with a missing, duplicated or
   out-of-range index, a wrong count or a wrong length is `unknown{malformed_response}`
   (the provider may have charged), never a shorter list; the response must name a
   nonempty served `model` equal to the requested allowlisted model ID, otherwise the
   call is `unknown{malformed_response}` with no vectors delivered (provenance keeps
   both the requested `model_ref` and the reported `provider_model`; model aliases and
   snapshots need a later Contract); one call sends at most one
   HTTP request; usage absent from the response is `:unknown`; the credential and the
   input texts never appear in results, errors, inspect values, logs or events. Two
   descriptors are compatible only when provider, model, dimensions, dtype and
   normalization are all equal; ELZ-082 relies on that. Non-goals: chunking (ELZ-081),
   storage (ELZ-082), similarity, int8 or binary dtypes, batch-mode submission (the batch
   slice), other providers.
3. **Reuse check.** `req_llm` 1.30.0 (`~> 1.30`, shared closure with ELZ-079).
   `ReqLLM.embed/3` takes a string or a list and options `dimensions`,
   `encoding_format`, `user`, `provider_options`, `req_http_options`
   (`lib/req_llm/embedding.ex:41-60,207-277`); a stub probe saw `POST /v1/embeddings` with
   `model`, `input`, `dimensions` and `encoding_format: "float"`. Facts the Contract
   answers, from stub probes without network: `embed/3` rejects a top-level
   `max_retries` but retries by default (4 requests on a stubbed timeout), while
   `req_http_options: [max_retries: 0]` gave exactly one; out-of-order `data[].index`
   values were reordered by index; a response with fewer vectors than inputs was returned
   as success; `req_llm` checks vector length only when `dimensions` was requested
   (`lib/req_llm/embedding.ex:340-372`) and does not normalize; usage carries
   `usage_reported` flags; no provider response or request id is returned (provenance
   records `response_id: :absent`). OpenAI documents unit-length vectors for its
   embedding models (provider documentation, an upstream claim, which is why the Adapter
   verifies the norm rather than assuming it). Anthropic has no embedding operation in
   `req_llm` (`lib/req_llm/providers/anthropic.ex:205,249,267`). Request conformance
   uses the embeddings schema from the official OpenAI OpenAPI document at a recorded
   commit, as in ELZ-079.
4. **Split test.** Embedding is an external Effect with cost and provider Needs; chunking
   and storage are separate Pieces; the interface and the provider are separate Pieces
   under the owner's model; further providers (Google, Mistral and others through
   `req_llm`; Voyage, Cohere and Cloudflare through thin own Adapters) are their own
   provider Pieces and tasks, each with a named caller (R1).
5. **Failure and evidence.** Dangerous paths: a short or reordered batch mapped to the
   wrong chunks; a vector of another dimension or model stored or compared; silent
   retries; unknown usage as zero; a key from the environment; input text in an error or
   log. Proofs: none required. Type/contract check: captured requests validate against
   the pinned OpenAI schema. Tests (stub-only, documented response format): single and
   multiple inputs; out-of-order indices reordered; fewer, more, duplicated and
   out-of-range indices `unknown{malformed_response}`; wrong vector length; non-finite
   value; norm verified and a non-unit vector reported `none` (or refused, per the
   builder's recorded choice); `dimensions` honored; usage reported and omitted; 400,
   401, 429, 500 mapped; timeout after send `unknown` with exactly one request observed;
   input bounds refused before dispatch; credential and input texts absent from results,
   errors, logs and events. Upstream: OpenAI embedding semantics and `req_llm`'s
   translation are named, not proved; no claim about embedding quality or about the live
   provider.
6. **Composition record.** The interface depends on `integration/ai-model` (ELZ-079
   core), `core/effect`, `delivery/effect-intent`, `delivery/retry-timeout`; the
   provider depends on the interface and is the only one with the `req_llm` provider.
   The provider records the R5 limit. Needs: the OpenAI
   key as an injected Need (never global config, never logged); network egress;
   `load_dotenv: false` as in ELZ-079. Telemetry `planned` (`req_llm` upstream events
   only); Config `supported` (binding, model allowlist, bounds, deadline;
   construction time; the norm tolerance is fixed by the Contract, not a setting); Control `not_applicable`.

## Scope

- add `pieces/integration/ai-embedding/` (interface, conformance kit in `lib/`) and
  `pieces/integration/ai-embedding-openai/` (provider, stub fixtures and the pinned
  OpenAPI schema extract with provenance), each with README, `piece.json` and tests;
- reuse the `req_llm` dependency added by ELZ-079 (no new package expected; if a new
  package is needed, the class X rule applies);
- add the two catalogue rows and release-plan entries, regenerate `LEDGER.md` and the
  roadmap views.

## Acceptance

- [ ] The listed scenarios pass against documented-format stubs, and captured requests
      validate against the pinned OpenAI schema.
- [ ] Every count, index, length or value defect in a response is
      `unknown{malformed_response}`; no partial list is returned.
- [ ] A timeout after send is `unknown` with exactly one request observed.
- [ ] No credential or input text appears in results, errors, inspect values, logs or
      Adapter events, with a test.
- [ ] The two Pieces' tests pass in the exported consumer layout.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] `mix check --affected <base>` and the Pieces' tests pass; full `mix setup` and
      `mix check` at the head if any dependency or configuration changed.

## Evidence and limits

Finite stub tests; request conformance against the pinned OpenAI schema; upstream
contracts of OpenAI and `req_llm`; no proof and no live call. No claim about embedding
quality, live provider behavior or cost.

## Out of scope

Other providers and dtypes, batch-mode submission, chunking, storage, similarity,
caching (none documented for embeddings in the sources read).

## Reference

Decision record `integration/ai-model`; owner decisions of 2026-11-09 (vector slice,
stub evidence, slice order); main's model-type research (embeddings section).

## Open questions (none blocks a builder)

1. `input_type`: OpenAI has no query or document distinction; recommended `unspecified`
   accepted and `query`/`document` refused for OpenAI, so a later Voyage Adapter can
   honor it without a Contract change.
