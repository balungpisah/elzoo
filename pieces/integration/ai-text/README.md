# integration/ai-text

The provider-neutral text-model interface of the `integration/ai-model` family:
request, response and outcome types, validation, a typed provider-options slot,
the provider behaviour, the call path through `core/effect` admission and the
`delivery/effect-intent` owner with bounded retries from
`delivery/retry-timeout`, and a provider conformance kit. Provider Pieces (the
first is `integration/ai-text-anthropic`) implement `Elzoo.AiText.Provider`; a
consumer copies the interface plus only the providers it uses. Apache-2.0.

## Call path

1. `Elzoo.AiText.configure/1` builds the trusted Config: binding (a module using
   `Elzoo.AiText.Binding`, fixing the provider account), tenant, provider module
   and its construction term, the injected credential Need (a zero-arity
   function returning `{:ok, key}`), the model allowlist, bounds (request bytes,
   output-token cap, receive timeout), the result sink and, for image input,
   the optional artifact read Need and image bounds (see "Image input"). Fixed
   for its lifetime; no hot reconfiguration.
2. `Elzoo.AiText.admission/2` takes a `core/effect` declaration (untrusted,
   capability `integration/ai-text`, operation `generate`, command schema
   `elzoo/ai-text-request` version 1, explicit idempotency key and deadline; the
   payload is the request JSON described in `Elzoo.AiText.Request`). Every
   locally decided refusal (`invalid_request`, `unsupported_feature`,
   `too_large`, `input_unavailable`) returns here: **no intent is created, no
   credential is read and the provider's transport is not called**; a request
   with image parts calls the artifact Need once per image part. Otherwise it
   returns the intent key, identity, canonical argument bytes and deadline.
3. The host starts `Elzoo.EffectIntent` with `adapter_context: config` and
   advances `:dispatch`. `Elzoo.AiText.Adapter.send_effect/1` runs the neutral
   checks, resolves each image part through the artifact Need (any failure is
   the attested no-send `input_unavailable`), calls the provider's pure
   `translate/2`, then the credential Need, exactly one `call/2`, and
   `decode/2` or `classify_failure/1`. The Adapter never retries.
4. The typed outcome goes to the **volatile result sink** once per attempt
   (`{:outcome, attempt_id, outcome}`, or `{:sink_failed, attempt_id}` when that
   call failed). The completed envelope holds only the response id, an outcome
   digest and a process-local seal: content, tool arguments, credentials and raw
   provider bodies never enter EffectIntent state. No durable retention, replay,
   recovery delivery or exactly-once sink delivery is supplied.
5. `Elzoo.AiText.Retry.next/4` decides with the ready
   `Elzoo.RetryTimeout.classify/1`, `decide/3` and `backoff/2`.

## Outcomes

- `{:completed, %{content, tool_proposals, structured, finish, usage,
  provenance}}`; `finish` is `:stop | :length | :tool_calls | :content_filter |
  :refusal | {:other, raw}`; `usage` and `provenance` are the family core's values.
- `{:refused, reason, %{retry_after: seconds | nil}}`, reason one of
  `credentials_unavailable | input_unavailable | invalid_request |
  unsupported_feature | too_large | authentication_failed | permission_denied |
  throttled | overloaded | not_found`.
- `{:unknown, reason}`, reason one of `timeout | transport |
  malformed_response | provider_error`: possibly dispatched and charged.

Failure tags and their delivery results are the Cure decision
`Elzoo.AiTextOutcome` (`cure/elzoo/ai_text_outcome.cure`); the Binding compiles
the same table statically and `configure/1` refuses construction if the two
differ.

| Tag | Contract outcome | outcome / dispatch / error class | No-send attested |
| --- | --- | --- | --- |
| `credentials_unavailable` | refused | timed_out / not_dispatched / unavailable | yes |
| `input_unavailable` (Contract amendment 2) | refused | timed_out / not_dispatched / unavailable | yes |
| `provider_invalid_request`, `provider_too_large`, `authentication_failed`, `permission_denied`, `not_found` | refused | failed / dispatched / permanent | no |
| `throttled`, `overloaded` | refused | failed / dispatched / retryable | no |
| `provider_error`, `malformed_response` | unknown | unknown / dispatched / unclassified | no |
| `provider_timeout`, `timeout` | unknown | timed_out / unknown / unclassified | no |
| `transport`, `adapter_error` | unknown | unknown / unknown / unclassified | no |

**Throttling and overload (Contract amendment 1).** `throttled` and
`overloaded` are provider-reported rejections after the request reached
transport. The provider's documentation may say they come before generation;
that is an unverified upstream assumption, not a no-send attestation. They reach
the caller as retryable failures carrying the provider's `retry_after` and are
**not redispatched by default**: under the default `:redispatch_forbidden` mode
`Retry.next/4` decides `:unresolved`. A caller that retries does so explicitly
with a ground of its own: either it submits a **new logical request reference**
(a new intent), accepting and recording that the first request may have been
processed, or it reconciles the existing intent through
`delivery/effect-intent`'s grounds (Adapter no-send, provider final no-effect or
provider replay-safe). No provider ground exists in this slice, so only the
first path is available, and the interface never takes it on the caller's
behalf. Only `credentials_unavailable` and `input_unavailable` (attested: no
byte reached transport) are retried automatically, after `:rearm`, within the policy and the deadline.
`unknown` is never retried. This holds for every policy mode: even a
`:redispatch_idempotent` policy gets `:unresolved` for a dispatched or unknown
result, because no provider supplies a replay-safe ground.

## Invariants

- One call sends at most one HTTP request (the provider's `call/2`).
- The credential comes only from the injected Need, is shape-checked before the
  provider is called, and never appears in a result, error, inspect value, log,
  event or EffectIntent state; prompts and outputs never appear in errors or
  logs.
- Tool proposals are data: no Piece executes, resolves or loads a tool. A
  proposal whose arguments are not valid JSON, not an object, for an undeclared
  tool, or not matching the declared schema is returned with `malformed` set and
  `arguments: nil` (the raw text is kept), never dropped or repaired.
- A structured output is returned `{:valid, value}` only after validation
  against the requested schema (`jsv`, draft 2020-12, no remote references),
  otherwise `{:invalid, reason}`.
- A 2xx without a response id or a recognized stop reason, or with an invalid
  usage value, is `unknown{malformed_response}`.
- A usage counter the provider did not report is `:unknown`, never zero.
- A cache hint whose tenant differs from the Config tenant is refused
  `invalid_request`; a hint the provider cannot express exactly is refused
  `unsupported_feature`, never dropped. Tenants sharing one provider credential
  share that provider's prompt cache: where isolation matters, configure one
  credential per tenant.
- Provider options: a key the provider does not declare, or a value its
  validator refuses, is `invalid_request`, never ignored. API version,
  credential, retry and timeout settings are construction settings, not options.
- Optional neutral features (`tools`, `structured_output`, `sampling`,
  `stop_sequences`, `cache_hint`, `reasoning`, `image_input`) are declared by
  the provider's `capabilities/0`; an undeclared one is refused
  `unsupported_feature` at admission. Document parts and members, audio and
  video input and provider-executed tools are refused `unsupported_feature`.

## Image input (Contract amendment 2)

- A `"user"` message may be `{"role": "user", "parts": parts}` instead of
  `{"role": "user", "text": ...}`: 1..64 parts, each `{"type": "text", "text":
  string}` or `{"type": "image", "artifact": {"id": artifact_id, "version":
  1..2^31-1}, "media_type": media_type}`, at least one an image, at most 8
  image parts in the request. `artifact_id` is as in `state/artifact` (1..64
  bytes of letters, digits and `-_.`); `media_type` is one of `image/png`,
  `image/jpeg`, `image/webp`, `image/gif`. The canonical request holds
  references only and keeps its 65,536-byte bound.
- `Request.decode/2` and `check/2` decide, before any Need call: a part of
  another type (`"document"` among them), `parts` on another role and an
  `"image"` or `"document"` member are `unsupported_feature`; `text` with
  `parts`, text parts only, more than 64 parts and a part with a missing or
  extra member are `invalid_request`; a ninth image part is `too_large`; a media
  type outside the set is `unsupported_feature`; image parts to a provider
  without `:image_input`, or to a Config without an `artifacts` Need, are
  `unsupported_feature`.
- `configure/1` takes `artifacts`, a one-arity Need given `%{artifact_id,
  version}` that returns what `Elzoo.Artifact.get/4` returns (the host wraps it
  with its own store and caller), and `image_bounds`, `%{max_image_bytes:
  1..5,242,880, max_total_image_bytes: 1..41,943,040}` (default 5,242,880 and
  20,971,520). This Piece does not call `state/artifact` itself.
- After the neutral checks and before `translate/2`, the interface calls the
  Need once per image part, in order. It accepts `{:ok, %{record, bytes}}` only
  when the record names the referenced `artifact_id` and `version`,
  `byte_size(bytes)` equals `size_bytes` and `sha256` equals the lowercase hex
  SHA-256 of `<<hash_format::8, bytes>>`. A record media type other than the
  part's, or an image of zero bytes, is `invalid_request`, decided after the
  hash, so an empty answer whose record or hash does not match stays
  `input_unavailable`, and no provider is sent an empty image. An image over
  `max_image_bytes`, or all images over `max_total_image_bytes`, is
  `too_large`; any other failure (an error, a raise, another shape, a
  mismatch) is `input_unavailable`. At admission these
  are local refusals before any intent; in the Adapter any of them is the tag
  `input_unavailable`, attested no-send, before the credential Need.
- The provider's `translate/2` gets each image part as `%{type: :image,
  media_type: m, bytes: bytes}`. Image bytes never enter the intent's
  arguments, its Store, an outcome, an error or `inspect`.
- Usage: the interface adds no counter. A provider that reports an image count
  reports it in the existing `:images` unit; image input tokens are in the
  input token counters as the provider reports them.
- Limits: the Need, its caller and its access check are the host's; the
  interface checks only that the bytes match the record it is given. A changed
  artifact cannot change an admitted request, because versions are immutable,
  but a deleted one makes the dispatch fail `input_unavailable`. The interface
  bounds an image only after the Need returns its bytes: an accepted call
  hands `translate/2` at most the total image bound (20 MiB by default), read
  twice (admission and dispatch), but before a refusal the interface may
  already hold whatever the Need returned. What the Need downloads is the
  host's to bound, for example by the record's `size_bytes` before it reads
  the object. No image-capable provider is part of this Piece, so no
  provider's image handling is evidenced here.

## Conformance kit

`Elzoo.AiText.Conformance` holds provider-neutral scenarios (text completion,
each finish reason, tool proposal well-formed, invalid JSON and schema-invalid,
structured valid and invalid, usage omitted, malformed 2xx, timeout after send,
throttled, overloaded, server error) and plain check functions returning `:ok`
or `{:error, scenario, reason}`. `image_scenarios/0` holds `:image_input`, for
a provider that declares `:image_input` only: a text part and a PNG image part
(`image/0`) from the Need double `image_need/0`, with a stub completion;
`scenarios/0` keeps the 15 above. A provider's own test supplies documented-format
stub responses and the observed request count; the kit has no ExUnit or
test-only dependency and imports no provider fixture.

## Grounding, operations and limits

- Type/contract check: pinned Cure compiles the outcome decision; the
  `delivery/effect-intent` Binding checks the failure table and the no-send set
  at build time. Not a proof of provider behaviour.
- Tests (`test/elzoo/ai_text_test.exs`, scripted test provider, volatile Memory
  store): call path, local refusals before intent and credential, provider
  options, retries (credential retried, throttled and overloaded not), one
  identity one send, the classification table against Cure, sink failures, tool
  and structured-output checks, request codec, a golden text-only request
  recorded before amendment 2, image parts (references only at admission,
  resolution in order, capability and Need refusals, bounds at their edges,
  integrity failures, the dispatch-time no-send and its retry, parts refusals,
  the `:image_input` conformance scenario), configuration and redaction.
  Finite scenarios, not proofs.
- Upstream contracts: the ready `core/effect`, `delivery/effect-intent` and
  `delivery/retry-timeout` Contracts; `jsv` 0.27.0; Jason; Cure, Elixir 1.20.4
  and OTP 29.1.2 (`:crypto` HMAC).
- Telemetry `planned` (no Elzoo event; provider libraries may emit their own).
  Config `supported` at construction only. Control `not_applicable`: dispatch,
  rearm and expiry are the EffectIntent owner's Control; a deadline cannot erase
  a dispatched call.
- Not supplied: streaming (the chunk shape is fixed in the core), batch,
  document, audio and video input and image output, inline image bytes,
  provider-executed tools, routing, fallback, pricing,
  metering, conversation storage, agent loops.
