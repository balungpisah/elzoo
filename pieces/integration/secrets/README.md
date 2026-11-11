# integration/secrets

Opt-in synchronous credential release under host-vouched exact authority
(ELZ-105, [issue #197](https://github.com/balungpisah/elzoo/issues/197)).
One resolver and a small redacted wrapper; no process, store, cache, refresh,
backend registry or retry. Consumers may continue using their existing injected
credentials directly. This Piece changes no accepted Adapter Contract.

## API and fixed evaluation order

`Elzoo.Secrets.resolve(request, context)` returns `{:ok, credential}` or
`{:error, :malformed | :unavailable | :denied | :missing | :expired}`.

1. Request is an ordinary map with **exactly** `ref` and `scope`, each an
   opaque binary of 1..128 bytes. Invalid request is `malformed`, before any
   context validation or callback. Identifiers are compared by byte equality,
   without normalization, hierarchy or wildcards, and must not contain secrets.
2. Trusted context is an ordinary map with required `grant` and `resolver`,
   optional `clock`, and no extra keys. Grant is `:deny` or an exact request-shaped
   map; resolver is a two-argument function; clock is a zero-argument function.
   Invalid context is `unavailable`, even if the grant would deny. Default clock:
   `System.system_time(:millisecond)`.
3. `:deny` or a grant unequal to the request is `denied`, without invoking callbacks.
4. Resolver runs once as `resolver.(ref, scope)`. Its success is exactly
   `{:ok, %{ref: ref, scope: scope, value: binary, version: integer,
   expires_at_unix_ms: integer}}`. It must bind the request exactly. Value is
   1..16,384 bytes; version is 1..9,007,199,254,740,991; expiry is Unix ms in
   0..9,007,199,254,740,991 (no nonexpiring marker). Invalid success is
   `malformed`. Explicit `{:error, :denied | :missing | :unavailable}` passes as
   the fixed tag. Any other return or catchable error/throw/exit is `unavailable`.
5. On valid bound success, the clock runs once **after** lookup. A catchable
   error/throw/exit or value outside the nonnegative Unix-ms range above is
   `unavailable`. `now >= expires_at_unix_ms` is `expired`; otherwise success.

`%Elzoo.Secrets.Credential{}` has only `value`, `version` and
`expires_at_unix_ms`. Its default Inspect is the constant
`#Elzoo.Secrets.Credential<redacted>`, including metadata redaction.
`Elzoo.Secrets.reveal(credential)` returns the raw binary and **does not**
recheck expiry or revocation. It is an integration convention, not access control.

## Optional text credential Need

An application can supply its existing `integration/ai-text` zero-arity Need:

```elixir
credentials = fn ->
  request = %{ref: "anthropic-key", scope: "tenant-a/anthropic/text"}
  context = %{
    grant: MyApp.Authority.current_credential_grant(),
    resolver: &MyApp.Credentials.current_snapshot/2
  }

  case Elzoo.Secrets.resolve(request, context) do
    {:ok, credential} -> {:ok, Elzoo.Secrets.reveal(credential)}
    {:error, _} -> {:error, :credentials_unavailable}
  end
end
```

These application functions are consumer-owned, not supplied here. Obtain fresh
authority inside the Need, not once at configuration time. The existing text
Adapter retains its narrower 1..1024 printable-ASCII-byte check: a valid snapshot
can still be refused as `credentials_unavailable`, before a provider call.
No fallback/retry/result Contract changes and no mandatory adoption follow.
The optional composition is tested in the repository's root
`test/secrets_integration_test.exs`; it is not a Piece source dependency.

Multi-field credentials may be encoded in one binary snapshot and decoded by
consumer injection code. This Piece owns no credential codec or generic types.

## Needs, races and limits

The host authenticates callers, supplies fresh authority, and binds opaque
scope unambiguously to tenant, provider/target and purpose. Context, callbacks,
grant and clock must not come from model/tool request data. Neither reference
identity nor a matching map authenticates anyone.

The consumer resolver owns atomic, coherent current-version lookup. Calls
straddling rotation may receive different versions. Revocation after lookup
may still release a held old snapshot; subsequent lookups after committed
revocation must return denied or missing under the resolver's declared policy.
Separately sampled authority and lookup are not a transaction. The host owns
any stronger serialization.

Expiry holds only at the post-lookup time sample, not at network dispatch or
provider acceptance. Time accuracy and rollback are host assumptions.
Previously returned binaries, in-flight requests and issued bearer URLs cannot
be recalled. Callbacks run synchronously and may block indefinitely unless
the host or existing Adapter bounds execution. No automatic refresh or cache.

The Piece emits no logs, telemetry, audit records, receipts or model context;
its fixed errors contain no inputs, provider terms, exception messages or
stacktraces. Validation does not invoke user-defined Inspect or exception
messages. Default Inspect does not protect explicit reveal, raw serialization,
Map.from_struct, tracing, process inspection, crash dumps, callback logging,
retained binaries or compromised-VM access. No encryption, protected heap,
secure erasure, sandbox or universal secret detection is claimed.

## Config, grounding and copying

- Telemetry: `not_applicable`; no observations emitted.
- Config: `supported` per call for trusted resolver and clock choice, with
  exact arity/key validation; no global settings or hot updates. Grant is data.
- Control: `not_applicable`; no owned lifecycle.

Dependencies: no Pieces; only Elixir 1.20.4 and OTP 29.1.2 (Apache-2.0).
Local source is Apache-2.0. No new package, provider SDK or Cure law is added.
Platform contracts: [catch semantics](https://hexdocs.pm/elixir/1.20.4/Kernel.SpecialForms.html#try/1)
and [system time](https://www.erlang.org/doc/apps/erts/erlang.html#system_time/1).
Finite tests cover the declared schemas/failures, bounds, redaction traps and
barrier-controlled expiry/rotation/revocation schedules. They do not prove
global secrecy, host authentication or provider atomicity/revocation.

Use the source-catalogue copier after catalogue integration:
`mix elzoo.take integration/secrets --to <consumer>`. Take the two library
files, platform-only tests, README, piece.json and the Elzoo license/NOTICE.
No root Application is required. Application-owned copies use `Elzoo.*`;
libraries redistributing source must rename modules/MFAs as described in
the catalogue's consuming guide. Copying evidence does not certify edits.
