# ELZ-079 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `b9cf963900533a004cc16b300cd493363cbd540e`

Inputs read: live issue #153; the reviewed `docs/work/ELZ-079.md` and
`docs/work/ELZ-079-probes/p10.{exs,txt}`; `origin/main...` reviewed-SHA diff;
the catalogue disposition and RC-16; the capability, operational, consuming and
change-class guidance; ready Effect, EffectIntent, RetryTimeout, object-store and
notification Pieces; and pinned ReqLLM 1.30.0 and Req sources. Anthropic's
versioning and migration documentation was also checked as an upstream contract.

## Findings

1. **blocking — Q4, outcome table rows 11–12 and Open question 4.** The proposed
   option A is incompatible with the ready `delivery/effect-intent` Contract. Its
   no-send attestation has the fixed meaning “no request bytes reached transport,”
   and is the only adapter ground that permits rearm. A 429 or 529 is received only
   after the request reached the provider, so an upstream belief that generation did
   not start cannot change that fact or widen the existing attestation by binding.
   Do not use option A. Amend the task Contract before implementation, map those
   rows to `failed/dispatched/retryable`, and do not automatically redispatch them
   in RetryTimeout's default `redispatch_forbidden` mode. This preserves the
   provider-reported retryable label for a future provider idempotency/no-effect
   design without claiming that it authorizes a second request.

   Required issue amendment, exact replacement in the text-interface output
   paragraph:

   - Before: “`throttled` and `overloaded` are provider rejections before
     generation, retryable under `delivery/retry-timeout`; `unknown` is possibly
     dispatched and not retried by default.”
   - After: “`throttled` and `overloaded` are provider-reported rejections after
     the request reached transport. The provider documentation may describe them
     as before generation, but that is an unverified upstream assumption, not a
     no-send attestation. They map to `failed/dispatched/retryable` and are not
     automatically redispatched in `delivery/retry-timeout`'s default mode; a
     later retry needs a provider idempotency or final no-effect ground. `unknown`
     is possibly dispatched and not retried by default.”

   Update the table, Binding descriptor, I4/I6/A4, README, manifest and limits
   to match. This is a new Piece Contract being admitted, not a permissible
   semantic widening of ready `delivery/effect-intent`.

2. **blocking — Q2, `p10.exs:30-32`, `p10.txt:29-38`, and the Advanced Plugin
   proposal.** The probe records a non-2xx response but does not halt it: its
   response step always returns `{rq, Req.Response.put_private(...)}`. Its 429
   transcript consequently returns `%ReqLLM.Error.API.Request{...}`, directly
   contradicting the proposal's statement that the ReqLLM error step is never
   built. The supported path is real: ReqLLM 1.30.0 documents
   `prepare_request/4` plus `Req.request/1` as its Advanced Req Plugin API, and
   Req documents `Req.Request.halt/2` for a response step. However, the evidence
   does not establish the required implementation yet.

   Replace the step with one that first copies only bounded status, selected
   headers and raw usage, then calls `Req.Request.halt(request, response)` for
   every non-2xx response. Add stubs for 429, 529 and a redirect, asserting one
   observed request, the retained `request-id`/`retry-after`, a returned raw
   response rather than `ReqLLM.Error.API.Request`, and no response body or
   prompt in the adapter-visible failure. This is also what makes the
   one-request invariant true: p10 currently shows a live `:redirect` step and
   merely setting `max_retries: 0` does not by itself stop another request if a
   redirect is followed. Keep `max_retries: 0`; the pinned source makes it the
   controlling ReqLLM retry setting. Treat `req_http_options: [retry: false]`
   only as defense in depth, not as the evidence for retries-off.

3. **should-fix — Q1, Open question 1 and `p10.exs:13`.** Pinning
   `anthropic-version: 2026-10-21` and refusing sampling is consistent with the
   interface only if sampling is explicitly an optional neutral request feature,
   gated by `capabilities/0`, rather than a promise every provider implements.
   It is consistent with R3 because the provider refuses the feature explicitly
   instead of silently rewriting or dropping it; its own options slot remains
   available for declared Anthropic-only features. Add that clarification to the
   interface README/Contract and test it as an admission refusal before credential
   lookup or dispatch.

   The version claim is checkable: Anthropic's versioning page
   (`https://platform.claude.com/docs/en/api/versioning`) recommends the latest
   version and records `2026-10-21`; its migration page records that Messages
   requests containing `temperature`, `top_p` or `top_k` receive 400. ReqLLM's
   Anthropic provider accepts the `:anthropic_version` option and places it in
   the header, but defaults to `2023-06-01`. Thus p10's observed
   `2023-06-01` header is not evidence for the proposed pin. Re-run it with the
   pin, assert the exact header, and assert no sampling fields for a no-sampling
   request. The remaining risk is compatibility of ReqLLM 1.30.0's older request
   encoder with the newer wire version; named, schema-validated stubs limit that
   claim appropriately and must not be presented as live-provider verification.

4. **should-fix — Q2, credential and redaction invariants.** The direct plugin
   route does not intrinsically bypass key handling: ReqLLM resolves an explicit
   `:api_key` before its configured/environment lookup, and the provider builds
   the authentication header from that resolved credential. It still has ambient
   fallbacks when no key is passed. Therefore the adapter must validate and call
   the injected Need before invoking ReqLLM and always pass its value as
   `api_key:`; on a failed Need it must not call `prepare_request/4`. Retain the
   global `load_dotenv: false` configuration and exercise A8 across application
   restart as planned. Add a test with conflicting ambient sources and a distinct
   injected value, observed only through the stub's redacted comparison, to prove
   the wire used the Need. The source audit and A7 must cover error and telemetry
   paths introduced by ReqLLM, not only Elzoo's normal results.

5. **should-fix — Q3, interface call path and export layout.** Put the
   conformance kit in `pieces/integration/ai-text/lib/` as ordinary scenario data
   plus functions returning `:ok | {:error, scenario, reason}`. That is the
   right exported boundary: it lets each provider and copied consumer run the
   same provider-neutral expectations without exporting ExUnit macros or a
   test-only dependency. Keep stub Plugs, captured-request machinery and
   provider-format fixtures in the provider's test tree; the kit must not import
   them. Add an exported-layout consumer test that invokes the kit for the
   Anthropic provider and one that copies core plus interface only.

6. **should-fix — Q5, completed content delivery.** A caller-owned result sink
   is the minimal compatible route because EffectIntent retains only summaries
   and `status/1` deliberately omits payloads. Accept it only as volatile local
   delivery: the sink receives the typed outcome once from the send task, its
   failure/raise is contained, it never changes adapter classification or intent
   settlement, and a caller may receive only `{:sink_failed}` rather than content.
   State that no durable result retention, replay, recovery delivery or exactly-once
   sink delivery is supplied. The envelope should contain the bounded response
   identity/digest/seal only; do not put content, tool arguments, credentials or
   raw provider bodies in EffectIntent state or observations.

7. **should-fix — Q6, pure decisions and grounding.** Put the exact finite
   failure-to-delivery-result mapping in Cure, as the notification precedent does,
   because it is the typed boundary consumed by the Binding descriptor. Cure
   compilation is a type/contract check, not a proof of a provider result or
   transport stage. Keep accounting derivation in Cure only if the production
   ABI can represent `known(n) | unknown` without a translation shadow; otherwise
   write it once as a pure Elixir function with exhaustive table tests. In either
   case, test dual cache-total/detail reports for consistency, never double count
   them, and yield `:unknown` for an inconsistent or missing required component.
   Separate the manifest's Cure type-check, table tests, hand-derived schema
   validation, upstream contracts and unverified assumptions into their own
   grounding records.

8. **note — core, R4/R3 and provider boundary.** The core is right-sized: pure
   model/usage/cache/provenance/job/stream shapes and validators are shared across
   future type interfaces, while neutral text policy and the effect path remain
   in `integration/ai-text`, and wire translation/Need remain provider-specific.
   The tenant-equality rule is valuable but only prevents callers from naming a
   different tenant's local hint; it cannot partition Anthropic's provider cache
   for tenants sharing credentials. Preserve that limit. Require declared,
   validated provider-options keys; fixed API version, credential, retry and
   timeout settings belong to binding/config, not caller-supplied options. Keep
   one HTTP exchange per `call/2`, tools as inert proposals, absent usage as
   `:unknown`, and malformed 2xx as `unknown{malformed_response}`.

9. **note — Q7, export dependency and scope.** List `plug` as a provider for the
   Anthropic Piece and allow the exported consumer to resolve it as an ordinary
   dependency, because the exporter cannot preserve `only: :test` and copied
   tests use Req.Test/Plug. Keeping `only: :test` at the repository root is
   still appropriate. Do not mark ReqLLM `runtime: false`: its application is
   deliberately started for registry initialization, whereas the batch lesson
   says the consumer helper must not start runtime-false applications. The scoped
   three-Piece plus final shared dependency/configuration plan is otherwise
   coherent with the stated coordinator exception for class X; retain the local
   full `mix setup && mix check` requirement and explicit final review of pin,
   closure, license and `load_dotenv: false`. Each manifest must declare all
   three operational applicability records with supported settings tied to
   in-bundle tests, planned telemetry explicitly excluded, and call-scoped
   control not applicable.

## Answers to Q1–Q7

1. **Q1 — proceed after the clarification and stub evidence in finding 3.** The
   pin and refusal are sound for this provider variance; the upstream version
   documentation is citable. Do not claim ReqLLM natively supports the newer
   version beyond its header override and exercised documented-format stubs.
2. **Q2 — proceed after finding 2 and finding 4.** The Advanced Req Plugin API
   is documented and supported. Raw usage/header capture is demonstrated by p10;
   non-2xx halting, redirects, no ReqLLM error construction and ambient-key
   exclusion are not demonstrated by p10 and require the specified tests.
3. **Q3 — recommend the interface `lib/` conformance kit described in finding
   5.** It is reusable source, not test-framework glue.
4. **Q4 — reject option A.** Use the exact Contract amendment in finding 1 and
   map 429/529 to possibly-dispatched `failed/dispatched/retryable`, without
   automatic retry. A distinct provider-rejected/no-effect class is later work
   only if it carries a provider-final certificate compatible with EffectIntent.
5. **Q5 — recommend the bounded volatile sink, with the explicit limits in
   finding 6.** It preserves content confidentiality in EffectIntent storage.
6. **Q6 — recommend Cure for the classification decision; accounting derivation
   only if it is the one production implementation.** Do not call either a
   proof unless actual selected laws are checked.
7. **Q7 — recommend `plug` as the provider Piece's exported provider record and
   an ordinary exported dependency.** Keep its root scope test-only and test the
   copied layout.

## Verdict

**Proceed after fixes.** There are 2 blocking findings, 5 should-fix findings
and 2 notes. The required issue amendment and the corrected non-2xx/one-request
probe evidence should be resolved before implementation begins; no live provider
call is needed.
