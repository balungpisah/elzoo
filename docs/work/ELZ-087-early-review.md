# ELZ-087 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `dac9c143c1bf3b3b05d6862832fad8d9f6ee91d2`

Verdict: **proceed after fixes**.

Inputs reviewed: live [issue #157](https://github.com/balungpisah/elzoo/issues/157); `AGENTS.md`; the named SHA's `docs/work/ELZ-087.md`, `docs/work/ELZ-087-probes/p1.exs`, and `p1.txt`; `git diff origin/main...dac9c143c1bf3b3b05d6862832fad8d9f6ee91d2`; merged `integration/ai-model`, `integration/ai-text`, and `integration/ai-text-anthropic`; working-tree `req_llm` 1.30.0 and `llm_db` 2026.11.0. No Mix command or provider call was made. The official OpenAPI source named by the record was fetched read-only: commit `59f5565459caae84f43c49a738248cf2b268a70f` has the stated SHA-256 `287f2cbf81b668735c56853b5e2ec40048c8912bead00ac8118190fae9716392`.

## Findings

1. **High — the stated schema-validation evidence cannot cover intentionally invalid 2xx fixtures.**
   - Location: `docs/work/ELZ-087.md:224-228, 238-248`.
   - The plan says every 2xx stub validates as `Response`, while the required `malformed_success` fixture must lack an id or other required Response members. It also promises tests for absent counters, although a present `ResponseUsage` requires `input_tokens_details.cached_tokens` and `cache_write_tokens` in the pinned document. Those fixtures cannot both validate as documented `Response` values and exercise the defensive decoder paths.
   - Concrete change: split the claim and tests. Validate every documented-format success fixture and every ErrorResponse fixture; for malformed-success and partial-usage negative controls, assert that JSV rejects the fixture as `Response` and that the provider returns the prescribed `unknown` outcome/unknown counters without a second request. Do not call those negative fixtures documented-format stubs.

2. **Medium — exact cache-hint mapping is underspecified for valid interface message shapes.**
   - Location: `docs/work/ELZ-087.md:56-58, 121-127, 238-246`.
   - The shared request accepts one through 256 ordered messages and does not require exactly one system message. The proposal refers to “the (single) system message,” but does not define the no-system or multiple-system cases when `:system` is named; it also needs a precise stated index domain for `{:message, i}` after system messages are excluded. Leaving either implicit risks silently marking an unintended content part.
   - Concrete change: state and test the pre-send rule: only a unique, addressable target is mapped; missing/ambiguous system and non-user/absent message targets are refused (use the chosen fixed interface reason consistently), with zero requests. State whether `i` indexes the non-system sequence and test a mixed system/user/assistant/tool-result transcript.

3. **Medium — the cache-key claim overstates injectivity.**
   - Location: `docs/work/ELZ-087.md:113-118`.
   - Length framing is injective for the preimage tuple and SHA-256 is an appropriate collision-resistant, opaque derivation, but the final fixed-size hash is not mathematically injective. The planned tests demonstrate deterministic equality and selected tenant separation, not injectivity for all inputs.
   - Concrete change: say “unambiguous length-framed preimage; SHA-256 collision-resistant derived key,” retain the tenant-mismatch refusal and equal/different test vectors, and do not claim proof of tenant isolation beyond those controls and the provider's upstream cache-key contract.

4. **Medium — Responses status coverage needs evidence wording narrower than the proposed mapping.**
   - Location: `docs/work/ELZ-087.md:173-183, 257-263`.
   - At the pinned OpenAPI commit, `POST /responses` declares 200, 400, 404, 429 and 503. Its ErrorResponse schema can validate body shape for the other planned statuses, but does not establish that 401, 403, 413, 500, 502 or 504 are operation responses. In particular, the 503-to-overloaded meaning is an explicit upstream assumption, not a schema fact.
   - Concrete change: retain the conservative fixed mapping required by the interface and the 503 `overloaded` decision, but label the non-declared status treatment and 503 overload semantics as upstream assumptions/policy tested against stubs, rather than claim the Responses operation documents them. Keep 429 and 503 as failed/dispatched/retryable and not redispatched by default.

5. **Low — cache-key fixture evidence should include boundary encoding vectors.**
   - Location: `docs/work/ELZ-087.md:113-118, 238-244`.
   - Equal inputs and two different tenants are useful, but do not catch a delimiter/length implementation error.
   - Concrete change: add fixed expected-output vectors including a boundary pair such as tenant `"a"`, local key `"bc"` versus tenant `"ab"`, local key `"c"`, plus empty values only if the core validator permits them (it does not). Assert the `ez1.` prefix, unpadded base64url alphabet and 47-byte output.

## Decisions and recommendations

- **Model allowlist:** accept one static model, `gpt-6.1-terra`, and refuse all others before a credential read. `llm_db` 2026.11.0 reports it active, Responses-routed (`openai_responses`, `/responses`), with reasoning values `none|low|medium|high|xhigh|max`; `req_llm` 1.30.0 routes it to `:openai_responses`. Keep the runtime route assertion and do not add Chat Completions without distinct evidence.
- **Cache key:** accept `ez1.` plus base64url-without-padding of SHA-256 over 32-bit-length-framed tenant and local key, subject to finding 3. It protects against delimiter ambiguity and avoids sending raw identity material; it does not partition OpenAI's cache for consumers sharing a credential/project.
- **Hint mapping:** accept exact explicit-mode mapping for TTL `30m|12h` and one to four addressable system/user text breakpoints, with `:tools` refused. Apply finding 2 to every missing, ambiguous or non-user address before dispatch. With no hint, accept default implicit caching only if README and piece limits repeat the shared-credential tenant-isolation limitation; the safer alternative is explicit/no-breakpoint mode to disable it, but is not required by the present family Contract.
- **Cache writes:** accept translation. The pinned `ResponseUsage.input_tokens_details.cache_write_tokens` is required, and its optional `cache_write_tokens_details` contains required `ttl_30m_tokens` and `ttl_12h_tokens`; the total/breakdown agreement rule prevents double counting. Apply finding 1 to absent-counter negative controls.
- **503:** map to `overloaded`, with the scoped upstream-assumption wording in finding 4. Its existing outcome table gives the required failed/dispatched/retryable result and no default redispatch.
- **Sampling and stop sequences:** accept neither capability. The selected `req_llm` encoder omits sampling for this model path, and the pinned CreateResponse schema has no `stop`; each must be refused locally as `unsupported_feature`, not dropped.
- **Seven open questions:** (1) accept implicit caching without a hint with the explicit isolation limit; (2) accept no declared caller provider options, provided cache fields are clearly internal derivations and unknown options remain invalid; (3) refuse `tool_result.is_error: true`; (4) send reasoning `none` explicitly because model metadata defaults to medium; (5) fix `store: false`; (6) add the missing disposition row in the final shared-files change; (7) map a well-formed HTTP-200 Response with `status: "failed"` to `unknown{provider_error}`, not a completed `{:other, "failed"}` result.

## Required retained scope and evidence

- One request per call: retain `max_retries: 0`, Req `retry: false`, a prepended response step that halts every response, a halting error step, and one-request assertions for every non-2xx and post-send timeout.
- Credential: retain injected `api_key:` only; test conflicting environment, application config and `.env` sources without logging the values.
- Tools: callbacks must remain inert; raw malformed function arguments must reach the interface to be marked malformed; server-side tool requests are refused and server-side tool response items are malformed-response unknowns.
- Response parsing: retain malformed 2xx as `unknown{malformed_response}` and use the separated negative-control evidence in finding 1.
- Grounding: retain the pinned OpenAPI commit, source hash, extraction rule, MIT notice and fixture hash; state that this is a type/contract check and finite stub tests, not a proof or live-provider evidence.
- Operations: Telemetry `planned`, construction-time Config `supported` with in-bundle test evidence, Control `not_applicable` are correctly scoped. The fixed store/retry settings are construction-time, not hot reconfiguration.
- Export/README: source audits must derive their file set from this Piece's `piece.json` in both repository and copied-consumer layouts as applicable. Retain the README **Install configuration** section with the exact `config :req_llm, load_dotenv: false` line until ELZ-091 supplies the consumer-side configuration path.
- Scope: add only the OpenAI provider Piece, its fixtures/tests/metadata and required generated catalogue artifacts. No interface/core change, no new dependency, no live call, no Chat Completions, Azure, streaming, server-side tools, routing or unrelated implementation work.

## Evidence checked

The probe is appropriately a no-network, injected-key, one-Responses-request observation. It demonstrates `gpt-6.1-terra` routing, the `/v1/responses` path, explicit cache fields/breakpoints, `store: false`, a halting raw response body, and a tool callback that is not invoked; it does not by itself establish a provider Contract. The pinned OpenAPI source confirms `ResponsePromptCacheOptionsParam` TTLs/modes, `PromptCacheBreakpointConfig`, documented usage cache-write fields, and the `/responses` response codes above.

Counts: High 1, Medium 3, Low 1. No blocker/stop finding.
