# integration/ai-embedding

The provider-neutral embedding interface of the `integration/ai-model` family:
request, result, descriptor and outcome types, validation of every provider
response (count, indices, length, finiteness, served model, norm), a typed
provider-options slot, the provider behaviour, the call path through
`core/effect` admission and the `delivery/effect-intent` owner with bounded
retries from `delivery/retry-timeout`, and a provider conformance kit. Provider
Pieces (the first is `integration/ai-embedding-openai`) implement
`Elzoo.AiEmbedding.Provider`; a consumer copies the interface plus only the
providers it uses. It does not depend on `integration/ai-text`. Apache-2.0.

## Call path

1. `Elzoo.AiEmbedding.configure/1` builds the trusted Config: binding (a module
   using `Elzoo.AiEmbedding.Binding`, fixing the provider account), tenant,
   provider module and its construction term, the injected credential Need (a
   zero-arity function returning `{:ok, key}`), the model allowlist (each model
   declared by the provider), bounds (inputs per call, default 128, at most
   2,048; bytes per input, default 32,768; canonical request bytes, default and
   maximum 65,536), the receive timeout (default 60,000 ms) and the result sink.
   Fixed for its lifetime; no hot reconfiguration.
2. `Elzoo.AiEmbedding.admission/2` takes a `core/effect` declaration (untrusted,
   capability `integration/ai-embedding`, operation `embed`, command schema
   `elzoo/ai-embedding-request` version 1, explicit idempotency key and
   deadline; the payload is the request JSON described in
   `Elzoo.AiEmbedding.Request`). Every locally decided refusal
   (`invalid_request`, `unsupported_feature`, `too_large`) returns here: **no
   intent is created, no credential is read and the provider's transport is not
   called**.
3. The host starts `Elzoo.EffectIntent` with `adapter_context: config` and
   advances `:dispatch`. `Elzoo.AiEmbedding.Adapter.send_effect/1` calls the
   credential Need, the provider's pure `translate/2`, exactly one `call/2`,
   then `decode/2` or `classify_failure/1`, then the interface's response
   checks. The Adapter never retries.
4. The typed outcome goes to the **volatile result sink** once per attempt
   (`{:outcome, attempt_id, outcome}`, or `{:sink_failed, attempt_id}`). The
   completed envelope holds only an outcome digest and a process-local seal:
   vectors, input texts, credentials and raw provider bodies never enter
   EffectIntent state.
5. `Elzoo.AiEmbedding.Retry.next/4` decides with the ready
   `Elzoo.RetryTimeout.classify/1`, `decide/3` and `backoff/2`.

## Request

`{"version": 1, "model", "inputs": [text, ...], "dimensions"?, "input_type"?,
"provider_options"?}`. `inputs` holds 1..`max_inputs` nonempty UTF-8 strings,
each at most `max_input_bytes`. `dimensions`, when present, must be in the range
the provider declares for the model; absent means the model's native
dimension. `input_type` is `query | document | unspecified` (default
`unspecified`); a provider declares the values it honours and a value it does
not declare is refused `unsupported_feature` before any credential read (no
silent hint). `provider_options` keys must be declared by the provider and pass
its validator, otherwise `invalid_request`.

**The request bound.** The exact UTF-8 bytes of the canonical JSON command
payload (object keys sorted, no insignificant whitespace, Jason's string
escaping), which are the EffectIntent `arguments`, must be 1..65,536 bytes
(`max_request_bytes` may narrow it): the `delivery/effect-intent` argument
bound. Every member and all JSON escaping count; a larger request is refused
`too_large` before any intent, credential read or transport call. This is not an
HTTP-body limit. A raw payload over 1 MiB is refused `too_large` without parsing.

### Worked example: how many chunks fit in one call

With `"model": "text-embedding-3-small"` and no optional member, the canonical
payload is `{"inputs":[...],"model":"text-embedding-3-small","version":1}`: 58
bytes of overhead, plus for each input its UTF-8 bytes (after JSON escaping),
two quotes and one comma between inputs (`57 + k × (bytes + 3)` for `k`
inputs). For chunks of 2,000 graphemes (the `integration/text-chunking`
default):

| Chunk text | Bytes per chunk in the payload | Chunks per call |
| --- | --- | --- |
| ASCII without escapes | 2,003 | 32 |
| ASCII, every grapheme a newline (`\n` is escaped to 2 bytes) | 4,003 | 16 |
| Three-byte UTF-8 (most CJK) | 6,003 | 10 |
| Four-byte UTF-8 (for example emoji) | 8,003 | 8 |

A chunk of mixed text lies in between; quotes, backslashes and control
characters cost 2 bytes or more each once escaped. A caller sizes each group by
measuring the canonical payload (`Elzoo.AiEmbedding.Request.canonical/1`), not
by counting chunks, and treats a `too_large` refusal as its own signal to
split. A single chunk whose canonical text exceeds 65,476 bytes (with this model name) cannot be
embedded in one call. The table is checked by the "batch-size example" test.

## Outcomes

- `{:completed, %{embeddings: [%{index, vector}], descriptor, usage,
  provenance}}`; `vector` is a list of floats; `usage` and `provenance` are the
  family core's values (`provenance.model_ref.model_id` is the requested model,
  `provenance.provider_model` the served one).
- `{:refused, reason, %{retry_after: seconds | nil}}`, reason one of
  `credentials_unavailable | invalid_request | unsupported_feature | too_large |
  authentication_failed | permission_denied | throttled | overloaded |
  not_found`.
- `{:unknown, reason}`, reason one of `timeout | transport | malformed_response
  | provider_error`: possibly dispatched and charged.

## Response checks and the descriptor

Before any vector is delivered the Adapter requires exactly one item per input,
the indices exactly `0..length(inputs)-1` (no missing, duplicated or
out-of-range index), every vector exactly the expected dimension (the requested
`dimensions` or the model's native one), every element a finite number within
the float32 range (integers are taken as floats), and a nonempty served model
equal to the requested model. Any defect is `unknown{malformed_response}` with
no vectors, never a shorter or partial list. Only then are the items sorted by
their validated index, so input order is list order.

`descriptor = %{provider, model, dimensions, dtype: :float32, normalization}`
(`Elzoo.AiEmbedding.Descriptor`): `provider` is the provider name (for example
`"openai"`), `model` the requested model identifier, `dimensions` the validated
length. `normalization` is `:unit_l2_verified` when every vector of the call
satisfies `abs(norm_l2(v) - 1) <= 1.0e-3`; the tolerance is fixed by the
Contract and is not a setting, so the value has one meaning in every
descriptor. Otherwise the call completes with `normalization: :none`; a store
binding that requires unit vectors (such as a cosine index) refuses it. Two
descriptors are compatible only when all five fields are equal
(`Descriptor.compatible?/2`). `input_type` is not part of the descriptor. Model
aliases and snapshots are not supported: a served model other than the
requested identifier is malformed.

## Failure tags and delivery results

The Cure decision `Elzoo.AiEmbeddingOutcome`
(`cure/elzoo/ai_embedding_outcome.cure`) maps each failure tag to its Contract
outcome and to the delivery result; the Binding compiles the same table
statically and `configure/1` refuses construction if the two differ. The table
is the same as `integration/ai-text`'s, duplicated so the two interfaces stay
independently copyable:

| Tag | Contract outcome | outcome / dispatch / error class | No-send attested |
| --- | --- | --- | --- |
| `credentials_unavailable` | refused | timed_out / not_dispatched / unavailable | yes |
| `provider_invalid_request`, `provider_too_large`, `authentication_failed`, `permission_denied`, `not_found` | refused | failed / dispatched / permanent | no |
| `throttled`, `overloaded` | refused | failed / dispatched / retryable | no |
| `provider_error`, `malformed_response` | unknown | unknown / dispatched / unclassified | no |
| `provider_timeout`, `timeout` | unknown | timed_out / unknown / unclassified | no |
| `transport`, `adapter_error` | unknown | unknown / unknown / unclassified | no |

`throttled` and `overloaded` are provider-reported rejections after the request
reached transport (the family rule of ELZ-079 amendment 1): they reach the
caller with the provider's `retry_after` and are **not redispatched by
default**. A caller that retries submits a new logical request reference,
accepting that the first request may have been processed. Only
`credentials_unavailable` is retried automatically, after `:rearm`, within the
policy and the deadline; `unknown` is never retried, in every policy mode.

## Conformance kit

`Elzoo.AiEmbedding.Conformance` holds provider-neutral scenarios (single and
multiple inputs, reversed indices, fewer, more, duplicated and out-of-range
indices, wrong length, a null element, an element beyond float32, non-unit
vectors, another served model, usage omitted, malformed 2xx, timeout after send,
throttled, overloaded, server error), the neutral items each success stub lists
(`items/2`) and plain check functions returning `:ok` or `{:error, scenario,
reason}`. A provider's own test encodes the items in its documented format and
passes the observed request count; the kit has no ExUnit or test-only
dependency.

## Grounding, operations and limits

- Type/contract check: pinned Cure compiles the outcome decision; the
  `delivery/effect-intent` Binding checks the failure table and the no-send set
  at build time. Not a proof of provider behaviour.
- Tests (`test/elzoo/ai_embedding_test.exs`, scripted test provider, volatile
  Memory store): call path, the conformance kit, local refusals, the payload
  bound at exactly 65,536 and 65,537 bytes, response defects, the tolerance edge,
  retries, one identity one send, the classification table against Cure, sink
  failures, descriptor compatibility, configuration and redaction, the
  batch-size example and a source audit of this Piece's own files. Finite
  scenarios, not proofs.
- Upstream contracts: the ready `core/effect`, `delivery/effect-intent`,
  `delivery/retry-timeout` and `integration/ai-model` Contracts; Jason; Cure,
  Elixir 1.20.4 and OTP 29.1.2 (`:crypto` HMAC).
- Telemetry `planned` (no Elzoo event). Config `supported` at construction only.
  Control `not_applicable`: dispatch, rearm and expiry are the EffectIntent
  owner's Control; a deadline cannot erase a dispatched call.
- Not supplied: chunking, storage, similarity, int8 or binary dtypes, base64
  encoding, batch-mode submission, caching, model aliases.
