# ELZ-080 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `455007a9fe20d8b316ddb40b7c8d8bb8ac9a7071`

Inputs: `git show 455007a9fe20d8b316ddb40b7c8d8bb8ac9a7071:docs/work/ELZ-080.md`; its p1 probe and transcript; `git diff origin/main...455007a9fe20d8b316ddb40b7c8d8bb8ac9a7071`; live issue #159; issue #160; AGENTS.md; the operational and consuming contracts; merged ELZ-079 Pieces; `delivery/effect-intent`; and the pinned working-tree `req_llm` 1.30.0 sources. No files in the reviewed commit were changed, no Mix command was run, and no provider was contacted.

## Findings

1. **BLOCKING — requested model identity is not sufficient for the store compatibility guarantee.**
   - Exact location: `docs/work/ELZ-080.md:119-124,355-359` and live #159 Admission record §2.
   - The proposal puts the requested allowlisted ID in `descriptor.model` while retaining a different provider-reported model only in provenance. Equal descriptors could therefore represent different served model snapshots, while ELZ-082 will treat them as compatible. The recorded assumption that one ID always denotes one immutable model is not an enforceable boundary and does not protect an existing index after an alias is retargeted.
   - Concrete change: make the actual served model identity the compatibility identity, or reject a non-identical reported model before delivering vectors. For this initial provider, the least invasive rule is: require a nonempty response `model` equal to the requested allowlisted ID; otherwise return `unknown{malformed_response}` with no vectors delivered. Keep both requested `model_ref.model_id` and `provenance.provider_model` for audit, add a mismatch fixture, and state the rule in #159. If aliases/snapshots are intentionally supported later, they need an explicit canonical-equivalence table whose canonical served identity enters the descriptor.

2. **BLOCKING — the 64 KiB request ceiling is a new public narrowing and must be amended into the issue, with the correct byte boundary.**
   - Exact location: `docs/work/ELZ-080.md:63-83,365-368`; live #159 Admission record §2 currently says only “bounded”; `pieces/delivery/effect-intent/lib/elzoo/effect_intent/model.ex:82-89,299-304` limits its stored `arguments` binary to 65,536 bytes.
   - This is not merely an implementation detail: it rejects batches that the published issue otherwise leaves admissible and directs ELZ-082 to batch around it. It also does not cap the provider's wire representation; it caps only the byte string admitted as EffectIntent arguments. ELZ-081 permits chunks much larger than this, so a retrieval caller cannot assume every valid chunk can be embedded in one call.
   - Concrete change: amend #159 before implementation to declare `1..65_536` bytes for the exact UTF-8 canonical JSON command-payload binary passed as EffectIntent `arguments`, including JSON escaping and all request members; test exactly 65,536 and 65,537 bytes before intent/Need/transport. State separately that this is not an HTTP-body limit. Amend/coordinate #160 so its indexing caller explicitly groups only embeddings whose ELZ-080 command payload fits the admitted bound and handles an embedding refusal rather than assuming all valid ELZ-081 chunks fit.

3. **SHOULD-FIX — the proposed usage construction can accidentally encode an unreported cache-write total as reported zero.**
   - Exact location: `docs/work/ELZ-080.md:350-354`; `Elzoo.AiModel.Usage.from_provider/3` defaults absent `:cache_writes` to `[]` at `pieces/integration/ai-model/lib/elzoo/ai_model/usage.ex:127-150`, and the core defines an empty list as reported zero.
   - The recommended semantics say cache counters remain `:unknown`, but omitting `:cache_writes` when calling `from_provider/3` produces `cache_writes: []`, which asserts zero. That contradicts the core's unknown-accounting rule even though the output counter correctly becomes `:unknown`.
   - Concrete change: for a present valid OpenAI usage object pass `cache_read: :unknown`, `output: :unknown`, and `cache_writes: [%{ttl: "provider_default", amount: :unknown}]`; use `Usage.unknown/1` only when the entire usage object is absent. Add exact assertions for the cache-write record, cache-read/output counters, source, and `prompt_input_tokens/1` in E2.

4. **SHOULD-FIX — `unit_l2_verified` has configuration-dependent meaning that the five-field descriptor erases.**
   - Exact location: `docs/work/ELZ-080.md:111-126,365-368`; live #159 Admission record §2 says the norm is within a stated tolerance while #160 accepts descriptor equality as the compatibility rule.
   - Two results checked with tolerances `0.1` and `0.001` can carry identical descriptors despite different promised normalization bounds. A consumer that receives only the descriptor cannot determine which promise its cosine declaration is relying on.
   - Concrete change: either fix one interface-wide tolerance as part of the stable Contract, or include the verified tolerance (or a normalized bound with a documented ordering rule) in the descriptor/index declaration and update compatibility accordingly. Add cross-tolerance compatibility tests and amend #159/#160 together if the descriptor shape changes.

5. **SHOULD-FIX — p1 proves the combined halting setup, not the stated independent `max_retries: 0` control.**
   - Exact location: `docs/work/ELZ-080-probes/p1.exs:15-19,38-49` and `p1.txt`; `docs/work/ELZ-080.md:163-172,297`.
   - The transcript shows one timeout request with both `req_http_options: [max_retries: 0]` and the prepended error halt, and separately one request with the halt but no retry setting. It does not show the required timeout case with `max_retries: 0` and no Elzoo error halt; the proposal labels that only as future E5 evidence.
   - Concrete change: add that no-halt/`max_retries: 0` timeout probe and transcript before treating p1 as verification of the setting, then retain E5 as the implementation regression test. The response and error halts remain required defense in depth; the result must still be exactly one observed request with each protection independently tested.

## Decisions requested

1. **`input_type`: recommend the proposal.** The interface should represent `query | document | unspecified`, with `unspecified` the default; OpenAI declares only `unspecified`, and it must refuse `query`/`document` as `unsupported_feature` before credential access or dispatch. Do not add a silently dropped hint mode. This preserves a future provider's ability to require and implement the distinction without evolving the request type.

2. **Failure table: recommend an own `Elzoo.AiEmbeddingOutcome` Cure decision with the same 14 tags and delivery triples.** Do not depend on `integration/ai-text`: a copied embedding source bundle must stand alone, and text is not a semantic dependency. Do not extract into ready `integration/ai-model` in this task: its accepted Contract intentionally gives each type interface its reason set, so changing it into a shared outcome-owner risks a ready-Contract evolution and creates unrelated scope. Record the duplicated table and its construction-time Binding equality check now; consider a new, separately admitted family outcome Piece only after another concrete consumer exposes the maintenance burden.

3. **Usage mapping: recommend it with the correction in finding 3.** OpenAI embedding `prompt_tokens` can be the provider input counter with `input_includes_cached: false`, because this embedding surface documents no cache accounting. Require a valid integer `total_tokens` equal to `prompt_tokens` when supplied (and make the input counter `:unknown` on absence, malformed values, or disagreement, per the selected conservative rule); cache-read, cache-write, and output remain unknown, never zero. This obeys the core identity: `input_uncached_tokens` remains the known prompt value, while derived `prompt_input_tokens` is unknown because cache components are unknown.

4. **Descriptor model: do not accept requested-ID-only compatibility without a response-identity guard.** A provider-reported snapshot different from the request makes requested-ID equality unsafe for ELZ-082. Use the strict-equality refusal described in finding 1 for the present OpenAI slice; a later alias-aware Contract may instead place a declared canonical served identity in the descriptor.

5. **OpenAPI extract: acceptable as a test fixture, not a `providers.json` provider.** `registry/providers.json` records adopted direct providers/pins that are exported to consumers, while this is copied test data rather than a runtime dependency. Keep the fixture under `test/fixtures`, preserve the source repository, immutable commit, source file SHA-256, retrieval date, and the complete applicable MIT copyright/permission notice inline or in an adjacent copied notice; mention it in Piece grounding. Do not describe its conformance check as evidence of live behavior.

6. **Bounds: yes, this is an issue amendment, and the right measured value is the canonical UTF-8 command-payload byte string retained as EffectIntent arguments.** The 65,536-byte cap follows the dependency exactly, but not the provider HTTP body; JSON encoding/escaping must happen before the byte check. The live issue and ELZ-082's calling contract need the explicit batching/refusal consequence rather than leaving it as a hidden configuration choice.

## Other review conclusions

The interface's count, exact-index-set, dimension, float32/finiteness, sorting, and norm checks are appropriately fail-closed; malformed success must remain `unknown{malformed_response}` with no partial vector list. The proposed one-request arrangement is sound in shape: use `req_http_options: [max_retries: 0]` and prepend response/error halting steps, but retain the independent evidence in finding 5. The proposed stub-only evidence, redaction testing, operational applicability (`telemetry: planned`, construction/per-call Config supported with test references, call-scoped Control not applicable), and provider/interface export separation are consistent with the existing ELZ-079 pattern once the findings are resolved.

## Verdict

**Proceed after fixes.** Counts: 2 blocking, 3 should-fix, 0 notes. No implementation should begin until the live issue amendment resolves the request cap and model-identity decision.
