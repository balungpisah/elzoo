# integration/webhook-out

Signed outbound events to tenant endpoints over a consumer-owned Ecto Repo on PostgreSQL 16,
under the `state/tenant-isolation` floor. A tenant registers HTTPS **endpoints** for named
events. The host **enqueues** an event once, and the Piece writes one **delivery** per endpoint
that listens for that name. Each send is one POST signed with the
[Standard Webhooks](https://www.standardwebhooks.com/) headers, through one
`delivery/effect-intent` intent per **try**.

The redelivery rule keeps the no-blind-resend rule of `delivery/effect-intent`:

- A refusal before any byte was sent (egress, DNS, the secret) is sent again on the same try
  after `Elzoo.RetryTimeout.delay/4`.
- A failure after which the request may have reached the receiver (a 5xx, 408 or 429, a timeout,
  a transport error) gets a new counted try with the **same `webhook-id`** only when the endpoint
  was registered with `dedup: true`, meaning that the receiver deduplicates by `webhook-id`.
- Every other endpoint, and a dedup endpoint at `max_tries`, goes to
  `delivery/dead-letter-store`.

This is not a generic webhook framework: it signs only the Standard Webhooks `v1` symmetric
scheme.

## Copy and providers

Select `integration/webhook-out` with `mix elzoo.take`. The copy is owned by the consuming
application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation`, `delivery/effect-intent`, `delivery/retry-timeout`,
`delivery/dead-letter`, `delivery/dead-letter-store`, `integration/egress-policy` and
`integration/secrets`. Providers: `ecto_sql` 3.14.0 and `postgrex` 0.22.4 (the Repo,
transactions and migrations), `req` 0.7.5 (the one POST), `jason` (canonical JSON), `otp`
(`:crypto` HMAC-SHA-256 and SHA-256, `:rand`, `Task`) and `elixir`. The tests also use `plug`
(the `Req.Test` receiver) and `telemetry`. Exact versions and claim-level grounding are in
[piece.json](piece.json).

## Migration

Call `Elzoo.WebhookOut.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration,
run by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix` and creates four tables, each protected with
`Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`, `space_column: nil`):

| Table | Key | Holds |
| --- | --- | --- |
| `elzoo_webhook_endpoints` | `(tenant, endpoint_id)` | URL, Secrets reference (`bytea`), sorted event names, `dedup` |
| `elzoo_webhook_events` | `(tenant, event_id)` | name, canonical payload JSON (`text`), its SHA-256 |
| `elzoo_webhook_deliveries` | `(tenant, delivery_id)`, `UNIQUE (tenant, event_id, endpoint_id)` | state, try, due time, lease, try deadline, rearm flag, counts, last-result triple, `dead_letter` (`none`, `pending`, `filed`) and the dead-letter record's inputs (reason, `dl_at_ms`) |
| `elzoo_webhook_observations` | `(tenant, delivery_id, try, attempt)` | the typed result of each send, and whether `record/3` applied it |

The deliveries table has a partial index for due pending rows and one for pending dead letters.
The prefix follows the identifier rule `^[a-z_][a-z0-9_]{0,62}$`. Anything else raises
`ArgumentError` with the fixed message `"invalid webhook-out prefix"` before any DDL. A `down/0`
is the consumer's. Install `Elzoo.DeadLetterStore.Migration` as well, in this schema or another.

Minimum grants for the application role, which must not own the tables or bypass row security
(no `DELETE` anywhere):

```sql
GRANT USAGE ON SCHEMA <prefix> TO <app role>;
GRANT SELECT, INSERT ON <prefix>.elzoo_webhook_endpoints, <prefix>.elzoo_webhook_events TO <app role>;
GRANT SELECT, INSERT, UPDATE ON <prefix>.elzoo_webhook_deliveries, <prefix>.elzoo_webhook_observations TO <app role>;
```

The application role also needs the `delivery/dead-letter-store` grants on its table. Call
`Elzoo.WebhookOut.verify(binding)` as that role at startup: it runs
`Elzoo.TenantIsolation.verify/3` on the four tables and returns `:ok` or the first error.

## Binding

Define one effect-intent Binding module, with the provider account that enters every intent
key:

```elixir
defmodule MyApp.Webhooks do
  use Elzoo.WebhookOut.Binding, provider_account: "myapp:webhooks", recovery_grace_ms: 60_000
end
```

Its Adapter ID is `webhook-out` and its operation `post`. The failure tags are:

| Tag | Result | Typed result |
| --- | --- | --- |
| `egress` | `rejected / not_dispatched / unavailable`, attested no-send | `{:not_sent, :egress}` |
| `dns` | the same | `{:not_sent, :dns}` |
| `secret` | the same | `{:not_sent, :secret}` |
| `unavailable` | the same (the row, the event, the transport Need or the clock) | `{:not_sent, :unavailable}` |
| `retryable` | `failed / dispatched / retryable` (408, 429, 5xx) | `{:failed, :retryable}` |
| `permanent` | `failed / dispatched / permanent` (3xx not followed, another 4xx) | `{:failed, :permanent}` |
| `timed_out` | `timed_out / unknown / unclassified` | `{:unknown, :timed_out}` |
| `transport` | `unknown / unknown / unclassified` | `{:unknown, :transport}` |

A 2xx is `completed / dispatched`, the typed result `:delivered`. Its envelope carries only a
process-local seal.

`Elzoo.WebhookOut.new(opts)` takes exactly these options and returns `{:ok, binding}` or
`{:error, :invalid}`. The binding is fixed for its lifetime, and its `inspect` is
`#Elzoo.WebhookOut<redacted>`.

| Option | Value |
| --- | --- |
| `repo`, `prefix` | the Ecto Repo and the schema of `Migration.install/1` |
| `policy` | one-arity Need given the tenant, returning `{:ok, Elzoo.EgressPolicy.policy/1 value}` |
| `resolver` | the `integration/egress-policy` resolver Need |
| `transport` | one-arity Need given `%{host, port, addresses}`, returning `{:ok, req_options}` |
| `secrets` | one-arity function from a Secrets request `%{ref, scope}` to its `Elzoo.Secrets` context |
| `clock` | trusted zero-arity Unix-millisecond clock, 0..2^53−1 |
| `retry` | an `Elzoo.RetryTimeout.policy/1` value for not-sent refusals, `max_attempts` at most 256 (an intent holds at most 256 attempts) and `max_backoff_ms` at most 2^53−1 |
| `max_tries` | 1..16 |
| `send_timeout_ms` | 1..60,000 |
| `try_deadline_ms` | 1,000..86,400,000, the intent deadline of a try after its first claim |
| `dead_letters` | an `Elzoo.DeadLetterStore` value |
| `effect` | `%{binding: module, provider_account: account}`, which must match the Binding's account |

The transport Need's options go into `Req.new/1`, and then the Piece merges `retry: false`,
`redirect: false`, `receive_timeout: send_timeout_ms` and an `into` function that discards the
response body. The Piece never sets `connect_options`: `Req.merge/2` would replace the host's
`connect_options` as a whole, and Req refuses `connect_options` beside a host `finch` pool, so
the host's pinning stays as given. The host connects only to the given `addresses`, with SNI and
the `Host` header set to `host`. The POST runs in a task that the Piece stops at
`send_timeout_ms`, which is then a timeout and also bounds the connect.

## Interface

Every function after `new/1` takes the binding, the tenant (the `domain/principal` text rule:
1..128 bytes of UTF-8 without a C0 or C1 control character) and one exact request map, except
`verify/1`.

| Call | Result |
| --- | --- |
| `register(b, tenant, %{endpoint_id, url, secret_ref, events, dedup})` | `{:ok, :applied}`; `{:ok, :duplicate}` for an equal URL, reference, event set and `dedup`; `{:error, :conflict}` for others; `{:error, {:egress, reason}}`, with nothing written |
| `enqueue(b, tenant, %{event_id, name, payload})` | `{:ok, %{deliveries: n}}`; `{:ok, :duplicate}` for equal name and canonical bytes, which writes nothing; `{:error, :conflict}` for others |
| `claim_due(b, tenant, %{limit, lease_ms})` | `{:ok, tries}`, oldest due first |
| `record(b, tenant, %{delivery_id, try, attempt, fallback})` | `{:ok, :applied}`, `{:ok, :duplicate}`, `{:ok, :no_result}` or an error below |
| `file_dead_letters(b, tenant, %{limit})` | `{:ok, %{filed: n, pending: m}}` |
| `status(b, tenant, %{delivery_id})` | `{:ok, %{state: :pending \| :delivered \| :dead_lettered, try, due_at_ms, claimed_until_ms, dead_letter: :none \| :pending \| :filed}}` |
| `verify(b)` | `:ok` or `{:error, reason}` |

Bounds:

- `endpoint_id` is a text of 1..128 bytes.
- `url` is at most 2,048 bytes, and `register/3` resolves it with
  `Elzoo.EgressPolicy.resolve/3` under the tenant's policy.
- `secret_ref` is a Secrets `%{ref, scope}` of two binaries of 1..128 bytes.
- `events` are 1..64 unique names; `name` is 1..128 bytes of `[a-z0-9._-]`.
- `dedup` is a boolean.
- `event_id` is 1..128 bytes of visible ASCII (0x21..0x7E), since it is sent and signed as the
  `webhook-id` header.
- `payload` is a JSON term (the `delivery/durable-mailbox` rule) of at most 65,536 bytes of
  canonical JSON: compact Jason, keys sorted by bytes.
- `limit` is 1..256, `lease_ms` 1,000..600,000, `try` 1..16 and `attempt` 1..256.

`delivery_id` is the lowercase hex SHA-256 of the canonical JSON `{"endpoint_id":…,"event_id":…}`
(64 bytes).

Errors are fixed atoms that never echo a URL, a payload or a secret: `:invalid`,
`:in_transaction`, `:isolation`, `{:egress, reason}`, `:conflict`, `:unknown_delivery`,
`:stale_try`, `:dead_letter` (the result was applied but its dead-letter put did not complete),
`:unavailable`. The endpoint, event and result maps may gain optional keys and the result and
error sets members, in place before the first release.

### A try

`claim_due/3` returns, for each try,
`%{delivery_id, endpoint_id, event_id, try, admission, rearm}`:

- `admission` is `%{key, identity, arguments, deadline}`. `identity` is
  `[tenant, provider_account, "webhook-out", "post", "<delivery_id>/try/<n>"]`.
- `arguments` are the canonical JSON of the tenant, delivery, endpoint, event and payload digest,
  never the payload.
- `deadline` is the try's first claim plus `try_deadline_ms`, fixed in the row, so a later claim
  gives equal admission parts.
- `rearm` is `true` when this try's last result was a not-sent refusal.

The host's worker, for each tenant that it serves, can do this (consumer code, not evidence):

```elixir
{:ok, tries} = Elzoo.WebhookOut.claim_due(b, tenant, %{limit: 64, lease_ms: 30_000})

for t <- tries do
  # Start a new owner, or keep the live one of this key; a restarted owner is read-only.
  pid = MyApp.Intents.owner(t.admission, binding: MyApp.Webhooks, adapter_context: b)
  if t.rearm, do: Elzoo.EffectIntent.advance(pid, :rearm)

  fallback =
    case Elzoo.EffectIntent.advance(pid, :dispatch) do
      # The Adapter stores its result before the send task ends.
      {:ok, :dispatched} ->
        MyApp.Intents.await_settled(pid)
        nil

      # Refused. Past the try's deadline with no possibly sent attempt, the try has expired:
      # without :expired, every later claim returns the same try again.
      {:error, _} ->
        if MyApp.Clock.now_ms() >= t.admission.deadline and MyApp.Intents.no_possible_send?(pid),
          do: :expired,
          # Otherwise read the owner as the fallback table below says (nil while unsure).
          else: MyApp.Intents.fallback(pid)
    end

  # The owner's attempt count, or 1 when it is 0 (an expired try that was never dispatched).
  %{attempts: n} = Elzoo.EffectIntent.status(pid)

  Elzoo.WebhookOut.record(b, tenant, %{
    delivery_id: t.delivery_id,
    try: t.try,
    attempt: max(n, 1),
    fallback: fallback
  })
end

Elzoo.WebhookOut.file_dead_letters(b, tenant, %{limit: 64})
```

The Adapter (`send_effect/1`) of a try:

1. It reads the endpoint, the event and the delivery under the tenant scope and checks the
   payload digest, the pending state and the try.
2. It resolves the URL again under the tenant's current policy.
3. It resolves the secret: `whsec_` followed by the base64 of 24..64 bytes.
4. It calls the transport Need with the addresses and reads the trusted clock.
5. It makes exactly one POST. The body is the canonical payload, with
   `content-type: application/json`, `webhook-id` (the `event_id`), `webhook-timestamp` (the
   clock in seconds) and `webhook-signature: v1,<base64 HMAC-SHA-256 over
   "<webhook-id>.<webhook-timestamp>.<body>">`.

Any failure in steps 1 to 4 is a not-sent result. Before it returns, the Adapter writes the typed
result as the observation of `(delivery_id, try, request.attempt)` in its own transaction. A
failure of that write does not change the envelope. `poll/1` returns
`{:unavailable, :no_status_query}`. The response body is not kept.

### `record/3`

It applies the observation of that attempt of the delivery's current try, under the delivery
row lock, once per `(try, attempt)`. A repeat is `{:ok, :duplicate}` and writes nothing, except
that it repeats the dead-letter put while the mark is `pending`. A result for another try is
`:stale_try`.

When no observation is stored, `fallback` is what the host read from the intent owner:

| `fallback` | When | Rule |
| --- | --- | --- |
| `nil` | | `{:ok, :no_result}`, nothing changes |
| `:delivered` | `status/1` shows the intent confirmed | delivered |
| `:unknown` | the intent is dispatched, stranded or recovered read-only with no result | possibly sent |
| `:not_sent` | a recorded no-send failure is the last attempt | not sent |
| `:expired` | the try's `deadline` has passed and the owner shows no possibly sent attempt; `attempt` is the owner's attempt count, or 1 when it is 0 | dead letter `deadline_before_dispatch` when no attempt of the try was dispatched, else `deadline_expired`; no new try |

A stored observation wins over every fallback but `:expired`. The Piece stores the fallback as
that attempt's observation. An Adapter write of the same attempt that committed, or is in flight,
before that insert wins over the fallback; one that comes after it changes nothing. So the host
names a fallback only once the owner shows that attempt's send task settled, or the owner is
recovered read-only.
`:expired` is applied once per try, whatever is stored for the attempt named (the owner's attempt
count, or 1 when it is 0, since `attempt` is 1..256), and is `:invalid`
before the deadline.

| Result | Effect |
| --- | --- |
| `:delivered` | `delivered` |
| `{:not_sent, _}` | the same try, due after `delay(retry, n, :retryable, %{failure_delay_ms: nil, random: r})`, with `n` the applied not-sent results of the try and `r` from `:rand` in the caller's process; the lease is cleared and `rearm` set; at `max_attempts`, dead letter `retries_exhausted` |
| `{:failed, :retryable}`, `{:unknown, _}` | `dedup: true` below `max_tries`: try `n + 1`, a new intent with the same `webhook-id`, due after `backoff(retry, n)`. `dedup: true` at `max_tries`: dead letter `retries_exhausted`. Any other endpoint, at any `max_tries`: dead letter `dispatched_unresolved` |
| `{:failed, :permanent}` | dead letter `permanent`, no new try |

The transaction that dead-letters a delivery sets `dead_letter` to `pending` and fixes the
record's inputs in the row: the reason, the applied-result count, the current try's last-result triple (none when that try
has no result) and
`at_ms` (the trusted clock). After the commit, `record/3` puts the `delivery/dead-letter` record
built from those inputs only, so every put of one delivery has equal bytes. The record is
`Elzoo.DeadLetterStore.put/3` with `source: "webhook-out"`, `work_ref` and `message_id` the
`delivery_id`, and `correlation_id` the `event_id`. `{:ok, :applied | :duplicate}` sets `filed`.
A crash or a failed put leaves the mark `pending` for `file_dead_letters/3`, which makes the same
put, oldest first. Two concurrent calls may put one record twice, which the store answers
`{:ok, :duplicate}`.

## Rules

- Writes check shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`),
  both before any query.
- They then run in `Elzoo.TenantIsolation.transact/3`, whose first query refuses any isolation
  level but read committed (`:isolation`). Every statement passes `log: false`.
- A refusal commits nothing. A database, Repo or clock failure is `:unavailable` and says nothing
  about whether a write committed.
- `claim_due/3` selects due pending rows whose lease has passed, `FOR UPDATE SKIP LOCKED`, and
  marks each with `claimed_until_ms` (now plus `lease_ms`) in the same transaction. So two
  workers take disjoint rows, and a second worker does not take a try until its lease passes.
- If a lease runs out mid-send, the next claim gives the same intent identity, and
  `delivery/effect-intent` recovers that intent read-only instead of sending it again.
- A try is never sent twice by this Piece; a new try is a new intent. The Piece never retries
  inside one call, and a crash after `enqueue/3` leaves the deliveries due for the next claim.

## Receiver verification

A receiver checks a request with the Standard Webhooks check. It decodes the base64 after
`whsec_` of its copy of the secret and computes the base64 of HMAC-SHA-256 over
`<webhook-id>.<webhook-timestamp>.<raw body>`. It compares that in constant time with each
space-separated `v1,<signature>` entry of `webhook-signature`, refuses a timestamp outside its
tolerance, and deduplicates by `webhook-id` when it was registered with `dedup: true`. The
Standard Webhooks libraries do all of this. A `webhook-id` is unique only within one tenant, so a
receiver that serves several tenants' endpoints scopes its deduplication by endpoint or by signing
secret as well as by `webhook-id`.

## Limits

- The `state/tenant-isolation` limits apply. The consumer Repo's query telemetry receives every
  parameter, including payloads, URLs and Secrets references.
- READ COMMITTED, the trusted clock, the transport Need's address pinning, the tenant policy and
  the host's `fallback` reading of an intent with no observation are host Needs.
- Req 0.7.5 with `connect_options: [hostname: h]` starts one Finch instance per distinct hostname
  and never stops it (`integration/egress-policy` README). Endpoint hosts are tenant-supplied, so
  the host's transport Need must pool or bound its connections itself.
- A delivered event is delivered at least once to a dedup endpoint and at most once to another.
  A receiver that does not deduplicate by `webhook-id` may see one event twice only if it was
  registered as deduplicating.
- Event payloads are kept with no expiry or purge in this version. A timestamp is the sender's
  clock.
- No live receiver is exercised: the evidence is a local receiver through the Req transport
  behind a resolver double, with no successful public connect.
- A `webhook-id` (the tenant's `event_id`) is unique only within one tenant: a receiver that
  serves several tenants scopes its deduplication by endpoint or secret.
- No endpoint disable, secret rotation, event filters, fan-out bound or asymmetric signature
  (`v1a`).

## Evidence

[test/elzoo/webhook_out_test.exs](test/elzoo/webhook_out_test.exs) runs on the worker's own
disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) behind a fail-closed target guard.
It uses `DBConnection.ConnectionPool` Repos, not the Sandbox, in a random schema dropped
afterwards. The application connections `SET ROLE` to `ELZOO_TEST_APP_ROLE` with only the grants
above. The effect-intent owners run on the volatile Memory Store, acknowledged with
`allow_volatile: true`, as `integration/ai-text`'s tests use it. These are finite scenarios, not
proofs. Row security, `SKIP LOCKED`, `ON CONFLICT` and read-committed re-reads are PostgreSQL's.
