# ELZ-105 — Scoped credential references

- Phase: V1 Pieces (RC-05)
- Catalogue IDs: `integration/secrets`
- Dependencies: ELZ-033 (#55/PR #56), ELZ-011 (#11/PR #94), ELZ-079 (#153/PR #164), all merged

Admit one opt-in callable boundary that releases a binary credential for an exact reference and scope under trusted host authority.

## Caller and compatibility

Concrete caller: an application using accepted `integration/ai-text` with its Anthropic provider needs a current tenant/provider/purpose-scoped API key through the existing zero-arity credential Need. Its host function obtains current authority, calls this Piece, reveals the binary only on success and returns `{:ok, key}`; every error maps to the existing `:credentials_unavailable` convention. No accepted Adapter, provider fallback, retry or result Contract changes. A multi-field credential may be encoded by the host into one binary snapshot and decoded by its own injection function, but this Piece provides no credential formats/codecs.

Historical planning prerequisites remain ELZ-033 and ELZ-011; add ELZ-079 for the demonstrated concrete caller. All are closed with accepted merges: #55/PR #56 `bc14b246c49f7bb31574321250d9583b8f91c5e5`, #11/PR #94 `70cb2cbbe6ab005ed61edd01d37dee1131afef5a`, #153/PR #164 `4e1694755b0a01b9153498e37ce9cbceefb893c9`. Planning prerequisites are not automatic source dependencies. New Piece source dependencies: none; platform providers Elixir 1.20.4 and OTP 29.1.2 only. Existing pins stay unchanged.

## Exact public API

`Elzoo.Secrets.resolve(request, context)` returns `{:ok, %Elzoo.Secrets.Credential{}}` or `{:error, reason}` where reason is exactly `:malformed | :unavailable | :denied | :missing | :expired`.

Request is an ordinary map with exactly `:ref` and `:scope`. Both are opaque binaries of 1..128 bytes, compared by exact byte equality, with no normalization, wildcard or implicit hierarchy. They contain identifiers, never credential values. The host owns an unambiguous binding from scope identifier to tenant, provider/target and purpose. Reference identity and scope labels authenticate nobody.

Context is a trusted host-created ordinary map with required `:grant` and `:resolver`, optional `:clock`, and no other keys. Grant is `:deny` or an ordinary map with exactly `:ref` and `:scope`, using the same bounds. Resolver is a two-argument function called once with the requested ref and scope. Clock is a zero-argument function, defaulting to `System.system_time(:millisecond)`. The host authenticates the caller and constructs a fresh grant from its current authority on every invocation; context, callback and clock must never be taken from model/tool request data. This is a trusted assertion, not an authentication or general authorization service.

Resolver success is exactly `{:ok, %{ref: binary, scope: binary, value: binary, version: integer, expires_at_unix_ms: integer}}`. Ref and scope must match the request. Value is 1..16,384 bytes. Version is 1..9,007,199,254,740,991. Expiry is Unix milliseconds in 0..9,007,199,254,740,991; no nonexpiring marker. The resolver owns atomic, coherent current-version lookup of all fields. Explicit resolver failures accepted are `{:error, :denied | :missing | :unavailable}`. No additional term is propagated.

Credential has only value, version and expires\_at\_unix\_ms fields. Its default Inspect prints a constant redacted marker, never values or metadata. `Elzoo.Secrets.reveal(credential)` returns the raw binary; it is an integration convention for trusted injection code, not enforceable access control. Version/expiry fields describe the sampled snapshot and provide no durable receipt. There is no automatic expiry/revocation check in reveal and no other lifecycle API.

## Fixed evaluation and failure order

1. Validate request exact shape and bounds; failure is malformed, without invoking callbacks.
2. Validate context exact shape, grant and function arities; failure is unavailable, without invoking callbacks.
3. Grant `:deny` or unequal ref/scope is denied before lookup.
4. Invoke resolver once. Catchable raise, throw or exit and unrecognized failure/return terms become unavailable. A tuple `{:ok, snapshot}` with an invalid snapshot shape/bounds/binding becomes malformed. Explicit denied/missing/unavailable are returned as their fixed tags.
5. On valid bound success, call the trusted clock once after resolution. Catchable failure or a return outside the same nonnegative Unix-ms range becomes unavailable.
6. `now >= expires_at_unix_ms` is expired; otherwise return the redacted credential wrapper. No truncation, fallback, refresh, retry or cached return.

No error includes request, reference, scope, resolver data, exception message, stacktrace or formatted term. Implementation must not invoke user-defined Inspect or exception-message protocols while checking or handling failure.

## Rotation, revocation and time

Resolver lookup is the snapshot boundary. Calls before a committed rotation may return the old version; later lookups return the new coherent version. Revocation after the snapshot but before return may still release the old value. The fresh post-resolution expiry sample does not recheck revocation. Future lookups after committed revocation must return denied or missing according to the host resolver's declared semantics.

Authority sampling and lookup are not a transaction. The host owns stronger serialization if it needs it. Expiry is valid only at the sampled instant, not at network dispatch or provider acceptance. Host wall-clock accuracy and rollback behavior are assumptions. Previously returned binaries, in-flight requests and issued bearer URLs cannot be recalled. No new timeout process exists: resolver/clock execute synchronously in the caller; a blocking callback can block indefinitely unless the host or existing Adapter bounds it.

## Redaction and operational applicability

The Piece emits no log, telemetry, audit record, receipt or model context. Default Inspect protects against accidental wrapper display only. It cannot prevent explicit reveal, raw term serialization, Map.from\_struct, tracing, process inspection, crash dumps, callback logging, caller retention or compromised-VM access. No encryption, secure erasure, protected heap or universal secret detection is claimed.

Telemetry: not\_applicable, no events. Config: supported per call for trusted resolver and clock choice, no global settings or hot-update API; grant is current authority data. Control: not\_applicable, no process/lifecycle. Consumer Needs are authentication/current authority, coherent atomic resolver snapshots, trusted time and safe handling of revealed bytes.

## Reuse and scope

Exact source/license comparison: [aws 1.0.15 archive](https://repo.hex.pm/tarballs/aws-1.0.15.tar) and [docs](https://hexdocs.pm/aws/1.0.15/AWS.SecretsManager.html), [ex_aws 2.7.0 archive](https://repo.hex.pm/tarballs/ex_aws-2.7.0.tar) and [docs](https://hexdocs.pm/ex_aws/2.7.0/ExAws.Config.html), [hush 1.3.0 archive](https://repo.hex.pm/tarballs/hush-1.3.0.tar) and [docs](https://hexdocs.pm/hush/1.3.0/Hush.html), and [cloak 1.1.4 archive](https://repo.hex.pm/tarballs/cloak-1.1.4.tar) and [docs](https://hexdocs.pm/cloak/1.1.4/Cloak.Vault.html). aws 1.0.15 Apache-2.0, ex\_aws 2.7.0 MIT, hush 1.3.0 Apache-2.0 and cloak 1.1.4 MIT were inspected from checksum-verified Hex archives. AWS retrieval, ExAws credential caching, Hush configuration materialization and Cloak encryption do not supply this scoped release policy. No package is adopted. Hush has runtime APIs and its core has no dependencies; historical boot-only/Hackney claims are not repeated.

Owned paths will be `pieces/integration/secrets/**`, `test/secrets_integration_test.exs`, task/work record, and coordinator-serialized own registry/planning rows and generated views. No vault/backend integration, environment/file loader, identity engine, store/process/cache, automatic refresh, new Assembly or ready Contract migration. Durable-job, Store/Writer, Relay, outbox and EffectIntent remain untouched. No ELZ-041/044 work or paid calls.

This task explicitly owns the root integration test. No generic secret lifecycle abstraction is in scope. Shared registry/planning edits require the coordinated handoff; reliability retains sole merge-queue ownership until an explicit handoff.

## Acceptance and grounding

Exercise success through the existing text credential Need with a local scripted provider in `test/secrets_integration_test.exs`; no live provider call. Include a valid printable key and a resolver-success/Adapter-refusal case, preserving the Adapter's narrower 1..1024 printable-ASCII-byte restriction. Keep Piece tests platform-only: the root test proves optional composition, while the standalone copied consumer proves declared closure. Test exact/cross-scope/ref denial before lookup, malformed request/context, authorized missing and unavailable, unknown resolver return, malformed/mismatched snapshot, boundary sizes, and secret-bearing raise/throw/exit with custom Inspect/exception-message traps. Check results, default Inspect, captured logs and any observed telemetry for synthetic secret markers.

Piece tests have no `ai-text` source dependency; the root test exercises actual `Elzoo.AiText` composition and runs alongside Piece tests.

Use barriers and a trusted test clock for expiry during blocked resolution and equality at expiry, coherent old/new versions across rotation, revocation during a held old snapshot (permitted old result), subsequent revoked lookup refusal, concurrent coherent reads, and previous returned bytes remaining available. Assertions must differentiate these schedules rather than infer ordering from sleep.

Run pinned mix setup, Piece tests, the root integration test explicitly and mix check --affected origin/main before push, plus a clean standalone copied consumer using only declared closure and no root Application. Full checks are required when current rules require them; hosted exact-head full evidence, independent named-SHA review, automated finding dispositions, coordinated queue, main acceptance and cleanup remain mandatory. Grounding is finite runtime/validation tests and named platform/host contracts; no new quantified Cure law, universal secrecy, provider revocation proof or deployment claim.
