# integration/oauth-client

A tenant's OAuth 2.0 **connections** to authorization servers that the host declares, in
PostgreSQL 16 over a consumer-owned Ecto Repo. A connection is made by an authorization code
grant with PKCE S256 that a tenant admin consents to once, or by a client credentials grant.
Its access and refresh tokens are stored only as
[`integration/encryption`](../encryption/README.md) envelopes. `access_token/3` hands out a
token only while it is fresh under the trusted clock; otherwise it makes one exchange under the
connection row lock, so concurrent callers make one exchange. `revoke/3` ends a connection.

Plain Elixir, Ecto, Postgrex, Req, Jason and OTP `:crypto`: the Piece writes only the token
lifecycle (when to exchange, one exchange at a time, sealing, revocation); Req and Jason make
and parse the wire formats, and no OAuth library is used (owner answer Q3 A). The first caller
is the OAuth credential of `integration/mcp-runtime`; its credential Need is

```elixir
fn -> Elzoo.OauthClient.access_token(binding, tenant, %{connection_id: id}) end
```

which meets the `{:ok, bearer_token}` rule of [`integration/mcp-client`](../mcp-client/README.md).

## Copy and providers

Select `integration/oauth-client` with `mix elzoo.take`; the copy is owned by the consuming
application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation`, `integration/secrets`, `integration/egress-policy` and
`integration/encryption`. Providers: `req` 0.7.5, `jason` 1.4.5, `ecto_sql` 3.14.0, `postgrex`
0.22.4, `elixir` and OTP `crypto`; the tests also use `plug` (the local authorization server is
a Req function plug) and `telemetry`. Exact versions and claim-level grounding are in
[piece.json](piece.json).

## Migration

Call `Elzoo.OauthClient.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration,
run by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix` (`CREATE OR REPLACE`), creates two tables and protects each with the tenant
floor (`tenant_column: "tenant"`, `space_column: nil`):

| Table | Columns | Keys |
| --- | --- | --- |
| `elzoo_oauth_connections` | `tenant`, `connection_id`, `provider_id`, `grant_type`, `scopes text[]`, `state`, `access_token bytea`, `refresh_token bytea` (envelopes or `NULL`), `obtained_at_ms`, `expires_at_ms`, `revision` | `PRIMARY KEY (tenant, connection_id)` |
| `elzoo_oauth_attempts` | `tenant`, `state_digest bytea` (SHA-256 of the `state`), `connection_id`, `scopes text[]`, `verifier bytea` (the sealed PKCE verifier), `expires_at_ms`, `used` | `PRIMARY KEY (tenant, state_digest)`, index on `(tenant, connection_id)` |

`prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the
fixed message `"invalid oauth client prefix"` before any DDL. Nothing is reversible by the
Piece. Rows are never deleted: a used or expired attempt stays, and a revoked connection keeps
its row with the tokens removed.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_oauth_connections, prefix.elzoo_oauth_attempts TO app_role;
```

Nothing else: no `DELETE`. The floor also needs the PostgreSQL defaults for PUBLIC: `EXECUTE` on
the two reader functions and, for `verify/1`, the database `TEMP` privilege (see the
`state/tenant-isolation` README). Call `verify/1` at startup, connected as the application role.

## Interface: `Elzoo.OauthClient`

Every function after `new/1` takes the binding, the tenant (1..128 bytes of printable UTF-8)
and one request map with exactly the listed keys.

- `new(opts)` returns `{:ok, binding}` or `{:error, :invalid}` and calls no Need. Options, each
  once:
  - `repo` and `prefix`;
  - `providers`: 1..64 maps, unique by `provider_id`, each exactly `%{provider_id,
    authorization_endpoint, token_endpoint, revocation_endpoint, redirect_uri, client_id,
    client_secret_ref, client_auth, scopes_allowed, refresh_rotation, default_lifetime_s}`.
    `provider_id` is 1..64 bytes of `[a-z0-9._-]`; the endpoints (`revocation_endpoint` may be
    `nil`) pass `Elzoo.EgressPolicy.check/2` under `policy`; `redirect_uri` is an `https` URL of
    at most 2,048 bytes without userinfo or fragment, only placed in requests, never fetched;
    `client_id` is 1..256 bytes; `client_secret_ref` is `nil` or a Secrets `%{ref, scope}`;
    `client_auth` is `:client_secret_basic`, `:client_secret_post` or `:none` (`:none` exactly
    when `client_secret_ref` is `nil`); `scopes_allowed` is 1..64 unique RFC 6749 scope tokens
    of 1..128 bytes; `refresh_rotation` is `true` when the provider may rotate refresh tokens;
    `default_lifetime_s` is `nil` or 1..31,536,000, the lifetime assumed for an access token
    whose response has no `expires_in`;
  - `policy` (an `Elzoo.EgressPolicy.policy/1` value) and `resolver` (the egress resolver Need);
  - `transport`: a one-argument Need given `%{host, port, addresses}` that returns
    `{:ok, req_options}`, a keyword list added to the Req request (production: options that
    connect only to the given addresses, with SNI and `Host` set to `host`; tests:
    `[plug: stub]`). The Piece sets `retry: false`, `redirect: false`, `compressed: false`,
    `raw: true`, its body collector and `receive_timeout` after the host's options, so they
    cannot be turned back on. It never sets `connect_options`;
  - `exchange_timeout_ms` (1..30,000, default 10,000): the bound of every exchange;
  - `secrets`: a one-argument function from a Secrets request to its trusted context;
  - `sealing`: `%{key_id, key, keys}`: `key_id` 1..128 bytes, `key` a zero-argument Need
    returning `{:ok, %Elzoo.Secrets.Credential{}}` (the current 32-byte key), `keys` the
    `Elzoo.Encryption.open/3` key Need;
  - `clock`: a zero-argument trusted Need returning Unix milliseconds (0..2^53−1);
  - optional `skew_ms` (0..3,600,000, default 60,000).

  `inspect/1` of the binding is `#Elzoo.OauthClient<redacted>`.
- A **connection** is `%{connection_id, provider_id, grant, scopes, state, expires_at_ms,
  revision}`: `grant` `:authorization_code` or `:client_credentials`; `state` `:pending`,
  `:active`, `:reauthorization_required` or `:revoked`; `expires_at_ms` `nil` or the access
  token's expiry by the trusted clock; `revision` from 1, bumped by every change of the row.
- `begin_authorization(b, tenant, %{connection_id, provider_id, scopes})` creates the connection
  `:pending` (grant `:authorization_code`), or takes an existing one of the same provider and
  grant in any state but `:revoked` (`:revoked` is returned); another provider or grant is
  `:conflict`. It records one attempt: a `state` of 32 random bytes, stored only as its
  SHA-256, and a PKCE S256 verifier of 32 random bytes, stored sealed, valid for 600,000 ms by
  the trusted clock. It returns `{:ok, %{authorization_url: url}}`: the authorization endpoint
  (its own query kept) with `response_type=code`, `client_id`, `redirect_uri`, `scope`,
  `state`, `code_challenge` and `code_challenge_method=S256`. **The URL holds the `state`**: it
  is the one result that carries a secret value of the attempt, so treat it like one.
- `complete_authorization(b, tenant, %{state, code})` takes the host's callback values (each
  1..2,048 bytes). An unknown, used or expired `state`, or one of another tenant, is
  `:invalid_state` before any exchange. The transaction that reads the attempt marks it used
  and commits before the exchange, so a `state` is used at most once, also when the exchange
  is refused or its outcome unknown. A refusal before any byte is sent (`:egress`,
  `:secret_unavailable`, `:seal`) commits nothing, and the `state` stays usable. Then one
  authorization code exchange; success makes the connection `:active` with the new sealed
  tokens and the attempt's scopes and returns `{:ok, connection}`; a refused, unknown or
  malformed exchange leaves the connection as it was.
- `connect_client(b, tenant, %{connection_id, provider_id, scopes})` creates an `:active` client
  credentials connection with no token: `{:ok, :applied}`, `{:ok, :duplicate}` for an existing
  one with equal provider, grant and scopes, `:revoked` for a revoked one of that provider, else
  `:conflict`.
- `access_token(b, tenant, %{connection_id})` returns `{:ok, token}` or `{:error, reason}`
  ("Tokens" below). It is the one function that returns a token value.
- `revoke(b, tenant, %{connection_id})` makes one RFC 7009 revocation call when the provider has
  a `revocation_endpoint` and the connection holds a token (the refresh token when there is
  one, else the access token, with its `token_type_hint`), then sets `:revoked` with the tokens
  removed whatever that call returns, also when it cannot be made: `{:ok, :applied}`. A repeat
  is `{:ok, :duplicate}` with no call.
- `get(b, tenant, %{connection_id})` returns `{:ok, connection}`, without any token.
- `verify(b)` runs `Elzoo.TenantIsolation.verify/3` for both tables and returns `:ok` or
  `{:error, {table, reason}}`.

Errors are `{:error, reason}` with one of the fixed atoms `:invalid`, `:in_transaction`,
`:isolation`, `:unknown_provider`, `:unknown_connection`, `:conflict`, `:scope`,
`:invalid_state`, `:not_active`, `:reauthorization_required`, `:revoked`, `:egress`,
`:secret_unavailable`, `:seal`, `:exchange_refused`, `:exchange_unknown`,
`:malformed_response` and `:unavailable`. No error echoes an ID, a URL, a token, a code or a
provider message. A connection of another tenant is `:unknown_connection` under row security.

## Exchanges

Each token exchange (authorization code, refresh, client credentials) and each revocation is one
POST of `application/x-www-form-urlencoded` to the provider's endpoint:

1. For an exchange that returns tokens, the sealing key Need, checked by a probe seal; a failure
   is `:seal`, before any byte, so a rotated refresh token is never received without a key to
   seal it.
2. `Elzoo.EgressPolicy.resolve/3` of the endpoint; an error is `:egress`, before any byte.
3. The client secret, when there is one, through `Elzoo.Secrets.resolve/2`, placed by
   `client_auth`: `client_secret_basic` as `Authorization: Basic` over the form-encoded
   `client_id:secret` (RFC 6749 section 2.3.1), `client_secret_post` as `client_id` and
   `client_secret` in the body, `none` as `client_id` in the body. A failure is
   `:secret_unavailable`, before any byte.
4. The transport Need with the resolved `%{host, port, addresses}`; a failure is `:egress`.
5. Exactly one Req request, with retries, redirects and compression off, in a task that the
   Piece kills (`Task.shutdown/2`, `:brutal_kill`) when it has not answered within
   `exchange_timeout_ms`. The Piece never repeats an exchange inside one call.

Its result is one of:

- **refused**: a 4xx; for a refresh, an `error` of `invalid_grant` is its own case;
- **unknown**: a 5xx, a 3xx (not followed), a transport error, or the task stopped at the bound;
- **malformed**: a 2xx whose body is not a JSON object of at most 65,536 bytes with a non-empty
  `access_token` of at most 4,096 bytes, `token_type` `bearer` (ASCII case-insensitive), an
  integer `expires_in` of 1..31,536,000 when present, an optional `refresh_token` of 1..4,096
  bytes and an optional string `scope`;
- **success**: `obtained_at_ms` is the clock before the request and `expires_at_ms` that plus
  `expires_in` (or `default_lifetime_s`) × 1,000. Without `expires_in` and with
  `default_lifetime_s` `nil`, `expires_at_ms` is the clock before the request, so the next
  `access_token/3` exchanges again.

A token returned by the exchange that this call just made is returned even when its lifetime
is shorter than `skew_ms`.

## Tokens

`access_token/3` reads the connection with `SELECT ... FOR UPDATE` in one transaction:

1. `:revoked` → `:revoked`; `:reauthorization_required` → `:reauthorization_required`;
   `:pending` → `:not_active`.
2. A fresh token → `{:ok, token}`, nothing written. A token is fresh when `expires_at_ms > now`
   and `expires_at_ms − now ≥ min(skew_ms, (expires_at_ms − obtained_at_ms) div 2)`: the skew,
   or half the token's lifetime when that is shorter, so a provider that issues tokens with less
   than `skew_ms` of life is not asked again by the next caller.
3. Otherwise, still holding the lock: a client credentials exchange for `:client_credentials`;
   one refresh with the stored refresh token for `:authorization_code` (none stored →
   `:reauthorization_required` is set and returned). Success stores the new tokens (a refresh
   response without `refresh_token` keeps the old one), bumps `revision` and returns the token.
4. A refresh refused `invalid_grant` sets `:reauthorization_required`; another refusal is
   `:exchange_refused` and changes nothing.
5. A refresh with an unknown or malformed outcome: with `refresh_rotation: true` the refresh
   token may be spent and is never sent again: the connection is set `:reauthorization_required`
   and that is returned. With `refresh_rotation: false` nothing changes and `:exchange_unknown`
   (or `:malformed_response`) is returned; the next call may refresh with the same token. A
   client credentials connection changes nothing on any failure: the next call asks again.

So two concurrent callers of one connection make at most one exchange. **The host's bound:**
the row lock, and one database transaction, are held for at most `exchange_timeout_ms` plus the
time of the Secrets, resolver, sealing key and transport Needs, which the host bounds; the
Repo's `:timeout` must exceed that time (Consumer Needs). A
`:reauthorization_required` connection takes a new consent through `begin_authorization/3`.

## Sealing

Every token and every PKCE verifier is sealed with `Elzoo.Encryption.seal/4` under
`sealing.key_id` and the current key, and opened with `sealing.keys`. The AAD is the canonical
bytes of `{tenant, connection_id, field}`: the ASCII tag `elzoo-oauth-client/1`, then each of
the three parts as a 32-bit big-endian byte length and its bytes; `field` is `access_token`,
`refresh_token` or `pkce_verifier`. An envelope copied to another tenant, connection or field
does not open. A failure to open is `:seal`. A per-tenant key is a host convention through
`key_id` and the key Needs.

## Writes

Every function except `new/1` and `verify/1` checks shape and bounds (`:invalid`), then
`repo.in_transaction?()` (`:in_transaction`), both before any query, then runs in
`Elzoo.TenantIsolation.transact/3` with scope `%{tenant: t}`, reads
`current_setting('transaction_isolation')` first and refuses anything but `read committed` as
`:isolation`. Every statement passes `log: false`. A refusal commits nothing. A database
failure is `:unavailable` and says nothing about whether a write committed.

## Consumer Needs

- PostgreSQL 16 and READ COMMITTED, the server default; the Piece checks the level but cannot set
  it. The migration runs as the table owner; the application connects as a non-owner role
  without `BYPASSRLS` or superuser, with the grants above.
- The Repo's `:timeout` (DBConnection's default is 15,000 ms) must exceed the time a call holds
  its transaction: the row-lock wait plus `exchange_timeout_ms` plus the time of the Secrets,
  resolver, sealing key and transport Needs. Every write runs in
  `Elzoo.TenantIsolation.transact/3`, which sets no transaction timeout of its own, so the Repo's
  value bounds the whole transaction. Otherwise the database can end a transaction while its
  exchange is still in flight: the call returns `:unavailable`, the tokens that the provider just
  issued are lost, and under rotation the next call sends the spent refresh token again and ends
  in `:reauthorization_required`.
- The trusted clock, the resolver, the Secrets context, the sealing key Needs and the transport
  Need are host Needs. The transport must connect only to one of the given addresses with SNI
  and `Host` set to `host`; the Piece cannot check that.
- The host passes the callback `state` and `code` only for its own redirect URI, and keeps the
  authorization URL as secret as the `state` it carries.

## Kept open

The provider map, the connection and the request maps may gain optional keys, and the grant,
state, `client_auth` and error sets may gain members, in place before the first release:
per-person connections (an optional `subject`, owner Q2 B); authorization server discovery
(RFC 8414) and MCP protected-resource metadata; dynamic client registration (RFC 7591);
private-key JWT client authentication; the device code grant.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them. The consumer Repo's query
  telemetry still receives the scope parameters (the tenant).
- READ COMMITTED is a consumer Need. A refresh holds a database transaction and the row lock open
  for one exchange.
- Req 0.7.5 with `connect_options: [hostname: h]` starts one Finch instance per distinct
  hostname and never stops it (`integration/egress-policy` README), so the host bounds the
  providers it declares or pools its own transport.
- The Piece emits no event, but upstream Req and Finch do: the `[:finch, :request, ...]`, `:send`
  and `:recv` telemetry events carry the `%Finch.Request{}`, whose body holds the `code`, the
  `code_verifier`, the `refresh_token`, the revoked token and, under `client_secret_post`, the
  client secret, and whose headers hold the `Authorization: Basic` value. Because the Piece
  collects the body with `into:`, Req 0.7.5 streams through `Finch.stream_while/5`, so the
  `[:finch, :request, :stop]` metadata `result` also holds the Req request (with the form) and
  the collected token response body: the new `access_token` and `refresh_token`.
  Consumer-installed handlers of those events can observe all of these; their collection and
  redaction are the consumer's responsibility.
- Attempt rows are never deleted (no `DELETE` grant): each `begin_authorization/3` adds one row
  with a sealed verifier, without a bound. Rate-limiting consent and pruning old attempts as the
  table owner are the host's.
- A `revoke/3` that commits while the code exchange of `complete_authorization/3` is in flight
  makes that call return `:revoked`; the tokens the provider just issued are dropped without a
  revocation call and stay valid at the provider until they expire.
- Tokens are sealed with one AES-256-GCM layer under the host's key: a person who holds the key
  and the database reads them. The authorization URL carries the `state`.
- A token without `expires_in` lives `default_lifetime_s`, or, with that `nil`, is exchanged
  again at the next call.
- A Repo that is not running is not a database failure: Ecto's Repo lookup raises, as in
  `domain/quota`.
- No live authorization server is exercised: the evidence is a local test server, a Req function
  plug through the transport Need behind a resolver double, with no socket and no successful
  public connect.
- No discovery, dynamic registration, JWT client authentication, device code, per-person
  connection, telemetry or log.
