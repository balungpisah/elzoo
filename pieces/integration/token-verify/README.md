# integration/token-verify

Offline verification of a bearer credential into a `domain/principal`
(ELZ-268, [issue #616](https://github.com/balungpisah/elzoo/issues/616)).
`Elzoo.TokenVerify` verifies a compact JWS bearer token (EdDSA or RS256)
against pinned public keys, or a prefixed API key against a keyed digest, and
returns `{:ok, %Elzoo.Principal{}}` or `{:error, reason}` with one fixed atom.
No network, clock read, key fetch (JWKS), OIDC login, refresh, session store,
JWE, account linking, log or telemetry. Plain Elixir; the time is the
caller's `now_unix_s`, an integer `0..9_223_372_036_854_775_807`.

## JWT

`Elzoo.TokenVerify.jwt_config(opts)` takes a keyword list with exactly one each
of:

- `issuer`, `audience`: 1..1024-byte UTF-8 strings, compared by exact bytes.
- `keys`: 1..16 atom-keyed maps with exactly `kid` (1..128 printable ASCII
  bytes, unique), `alg` (`"EdDSA"` or `"RS256"`) and `jwk`, a public JWK map
  with exactly `kty`, `crv`, `x` (OKP Ed25519) for EdDSA or `kty`, `n`, `e`
  (RSA, 2048..8192-bit modulus) for RS256. Private members, another key type
  or curve, or a key that does not match its `alg` are refused.
- `leeway_s`: integer `0..300`.
- `subject`: the host's account linking, called as
  `subject.(%{issuer: iss, subject: sub})` and returning
  `{:ok, %{principal: fields, current_epoch: n}}` (fields of
  `Elzoo.Principal.new/1` without `auth_epoch`) or
  `{:error, :revoked | :unknown_subject | :unavailable}`. It never receives the
  token.

Malformed configuration raises `ArgumentError` with a fixed message that holds
no option data. The config has a redacted `Inspect`.

`verify_jwt(token, config, now_unix_s)` returns a principal or one of
`:malformed | :unknown_kid | :invalid_signature | :bad_issuer | :bad_audience |
:expired | :not_yet_valid | :revoked | :unknown_subject | :unavailable`. The
first failing step decides:

1. `now_unix_s` in range, and the token a binary of at most 8,192 bytes with
   three non-empty unpadded base64url segments; else `:malformed`.
2. The protected header is a duplicate-free JSON object with `alg` `"EdDSA"`
   or `"RS256"` and a string `kid`, and none of `jwk`, `jku`, `x5u`, `x5c`,
   `x5t`, `x5t#S256` or `crit`; else `:malformed`. A header key is never used.
3. A `kid` that is not configured is `:unknown_kid`. A header `alg` different
   from that key's `alg` is `:invalid_signature`. Only that key verifies, with
   `JOSE.JWS.verify_strict(key, [key.alg], token)`; any other result is
   `:invalid_signature`.
4. The verified payload, decoded with ordered objects, is a JSON object with
   no duplicate key at any depth, string `iss` and `sub` (1..1024 bytes), `aud`
   a string or a list of 1..16 strings, integer `exp` and `iat` and optional
   integer `nbf`, each `0..2^63-1`; else `:malformed`. Then `:bad_issuer`,
   `:bad_audience` (`aud` does not contain `audience`), `:expired` when
   `exp + leeway_s <= now_unix_s`, and `:not_yet_valid` when `iat` or `nbf` is
   greater than `now_unix_s + leeway_s`.
5. Only then `subject` runs once. A raise, throw, exit or malformed result is
   `:unavailable`. The principal gets `auth_epoch` equal to `iat` (fields that
   `Elzoo.Principal.new/1` refuses are `:unavailable`), then
   `Elzoo.Principal.check(principal, %{current_epoch: n, revoked_ids: []})`:
   `:stale` is `:revoked`, a `current_epoch` out of range is `:unavailable`.
   So `current_epoch` is the host's "tokens issued before this Unix second are
   revoked" mark for the subject.

## API key

`api_key_config(opts)` takes exactly one each of `prefix` (1..16 bytes of
`[a-z0-9]`), `digest_key` and `lookup`, under the same `ArgumentError` rule:

- `digest_key`: zero-arity Need returning `{:ok, %Elzoo.Secrets.Credential{}}`
  whose revealed value is 32..64 bytes and whose `expires_at_unix_ms` is after
  `now_unix_s * 1000`. Anything else, an expired credential, or a raise is
  `:unavailable`.
- `lookup`: called as `lookup.(key_id)`, returning
  `{:ok, %{digest: <<_::256>>, principal: fields, current_epoch: n,
  expires_at_unix_s: integer | nil, revoked: boolean}}` (complete
  `Elzoo.Principal.new/1` fields), `{:error, :not_found}` or
  `{:error, :unavailable}`. Anything else or a raise is `:unavailable`.

A key is `<prefix>_<key_id>_<secret>`: `key_id` is 8..32 bytes of
`[A-Za-z0-9]` and `secret` exactly 43 unpadded base64url characters that
decode to 32 bytes and re-encode to the same characters (a non-canonical last
character is `:malformed`). The host stores
`HMAC-SHA-256(digest key, the 32 secret bytes)` for each key ID.

`verify_api_key(key, config, now_unix_s)` returns a principal or one of
`:malformed | :invalid_signature | :revoked | :expired | :unavailable`, in
this order: the shape of `now_unix_s` and the key (`:malformed`); `digest_key`
(`lookup` is not called when it fails); `lookup`; the digest comparison by
`:crypto.hash_equals/2`. An unknown key ID and a wrong secret both give
`:invalid_signature`. Only after a match: `revoked: true` is `:revoked`,
`expires_at_unix_s <= now_unix_s` is `:expired`, then the principal is built
and checked as in JWT step 5 with its own `auth_epoch`, `:stale` giving
`:revoked`.

## Secrecy

Failures are the fixed atoms only. No token, key, secret or digest-key byte
appears in a return value, a raised message or captured log output; a Need's
own exception is discarded. Needs receive only `iss` and `sub`, or `key_id`.
The configs keep a redacted `Inspect`; the digest key arrives as an
`Elzoo.Secrets.Credential` with its own redacted `Inspect` and is revealed
only inside the Adapter for the digest. This is accidental-disclosure protection, not memory erasure.

## Example

`examples/token_verify.exs` pins an Ed25519 key, verifies a token and a token
for another audience, and verifies an API key and a wrong one.

## Grounding

- Test: `mix test pieces/integration/token-verify/test` runs adversarial
  scenarios for every acceptance group of the issue: algorithm and key
  confusion, forbidden header members, shape and size limits, signed and badly
  signed malformed claims, time edges with leeway 0 and 300, issuer and
  audience, revocation, Need failures with call counts, API key shapes,
  secrecy and configuration. Negative controls: removing the `alg` allowlist,
  removing the forbidden-member check, trying every configured key instead of
  the one the `kid` names, and skipping the issuer check each make the tests
  fail.
- Upstream: jose 1.11.13 `verify_strict/3`, `peek_protected/1` and
  `from_map/1`. Drift tests call jose directly: it refuses `alg: none` and an
  HS256 token keyed with the RSA public PEM, and accepts EdDSA and RS256 with
  their own keys. OTP 29.1.2 `:crypto.mac/4` and `:crypto.hash_equals/2`;
  jason 1.4.5 ordered objects.
- No Cure law: the decisions are ordered checks around jose and OTP calls.

## Needs and limits

Needs: pinned genuine public keys, an accurate `now_unix_s`, and truthful
`subject`, `digest_key` and `lookup` Needs that do not log what they receive.
Needs run synchronously; the host bounds them.

Limits: no JWKS fetch or rotation, single-use `jti`, ES256, JWE or OIDC
ceremony; key-ID lookup timing is not constant (only the digest comparison
is); jose behaviour is an upstream contract pinned at 1.11.13. Telemetry and
Control are not applicable; Config is the two construction-time configs.

Dependencies: `domain/principal` and `integration/secrets`; providers jose
1.11.13, jason, Elixir and OTP `crypto`. Modules are application-owned under
`Elzoo.TokenVerify`. Apache-2.0.
