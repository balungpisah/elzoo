# ELZ-268 — Verify bearer JWTs and API keys offline into principals

- Phase: Wave 5 Level 1
- Dependencies: ELZ-033, ELZ-083, ELZ-105, ELZ-267
- Release: V1B
- Output: new `integration/token-verify` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/token-verify/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and reuse boundary

One bounded Adapter that verifies, offline and against pinned configuration, a compact JWS bearer token or a prefixed API key, and returns a `domain/principal` (ELZ-267) or one fixed failure atom. No network, clock read, key fetch (JWKS), OIDC login, refresh, session store, JWE, account linking or Ash. Plain Elixir; Cure only if a pure decision fits.

Reuse, without adding or changing a pin: `jose 1.11.13` (already locked through ELZ-083's `ex_mcp` and recorded in `registry/providers.json`), OTP 29 `:crypto` (`:crypto.mac(:hmac, :sha256, key, data)` and `:crypto.hash_equals/2`), `jason`, and the ready `integration/secrets` `Elzoo.Secrets.reveal/1` for the digest key. Declare the providers and Piece dependencies (`domain/principal`, `integration/secrets`) that the source, examples and tests use. Use public jose API (`JOSE.JWS.peek_protected/1`, `JOSE.JWK.from_map/1`, `JOSE.JWT.verify_strict/3` with a one-element algorithm list). A coordinator probe on `main` observed `verify_strict` accepting EdDSA and RS256 tokens with their own algorithm and returning `false` for `alg: none` and for an HS256 token keyed with the RSA public PEM; the tests must establish this themselves. If the Piece cannot compile or export without `jose` as a direct root dependency, stop and comment on the issue: that is a shared-path prerequisite task.

## JWT

`Elzoo.TokenVerify.jwt_config(opts)` takes a keyword list with exactly one each of `issuer`, `audience`, `keys`, `leeway_s` and `subject`, and returns an opaque config. Malformed configuration raises `ArgumentError` with a fixed message that contains no option data.

- `issuer`, `audience`: 1..1024-byte UTF-8 strings, compared exactly.
- `keys`: 1..16 maps with exactly `kid` (1..128 printable ASCII bytes, unique), `alg` (`"EdDSA"` or `"RS256"`) and `jwk` (a public JWK map: OKP Ed25519 for EdDSA; RSA with a 2048..8192-bit modulus for RS256). Private key members, another key type or curve, or a key that does not match its `alg` are refused.
- `leeway_s`: integer `0..300`.
- `subject`: an arity-1 Need, called as `subject.(%{issuer: iss, subject: sub})`, returning `{:ok, %{principal: fields, current_epoch: n}}` where `fields` are `Elzoo.Principal.new/1` fields without `auth_epoch`, or `{:error, :revoked | :unknown_subject | :unavailable}`. This is the host's account linking; it never receives the token.

`Elzoo.TokenVerify.verify_jwt(token, config, now_unix_s)` returns `{:ok, principal}` or `{:error, reason}` with `reason` in `:malformed | :unknown_kid | :invalid_signature | :bad_issuer | :bad_audience | :expired | :not_yet_valid | :revoked | :unknown_subject | :unavailable`. `now_unix_s` is a caller-injected integer `0..9_223_372_036_854_775_807`; this Adapter reads no clock. Order:

1. `now_unix_s` and token shape: a binary of at most 8,192 bytes with three base64url segments, else `:malformed`.
2. Protected header: a JSON object with `alg` in `{"EdDSA", "RS256"}` and a `kid` string; any of `jwk`, `jku`, `x5u`, `x5c`, `x5t`, `x5t#S256` or `crit` is `:malformed`. A header key is never used.
3. `kid` not configured is `:unknown_kid`. Header `alg` different from that key's `alg` is `:invalid_signature`. Verify with that key and `[key.alg]` only; failure is `:invalid_signature`.
4. Claims: a JSON object with string `iss` and `sub` (1..1024 bytes), `aud` a string or a 1..16 list of strings, integer `exp` and `iat`, optional integer `nbf`, each integer `0..2^63-1`; else `:malformed`. Then `iss` ≠ `issuer` is `:bad_issuer`; `aud` not containing `audience` is `:bad_audience`; `exp + leeway_s <= now_unix_s` is `:expired`; `iat` or `nbf` greater than `now_unix_s + leeway_s` is `:not_yet_valid`.
5. Call `subject` once, only after steps 1–4 pass. A raising or malformed result is `:unavailable`. Build the principal with `auth_epoch` equal to `iat` (host fields that `Elzoo.Principal.new/1` refuses are `:unavailable`), then `Elzoo.Principal.check(principal, %{current_epoch: n, revoked_ids: []})`; `:stale` is `:revoked`. So `current_epoch` is the host's "tokens issued before this Unix second are revoked" mark for the subject.

## API key

`Elzoo.TokenVerify.api_key_config(opts)` takes exactly one each of `prefix` (1..16 bytes of `[a-z0-9]`), `digest_key` and `lookup`, with the same `ArgumentError` rule.

- `digest_key`: zero-arity Need returning `{:ok, %Elzoo.Secrets.Credential{}}` whose revealed value is 32..64 bytes, or `{:error, _}`. Anything else, or raising, is `:unavailable`.
- `lookup`: arity-1 Need called as `lookup.(key_id)`, returning `{:ok, %{digest: <<_::256>>, principal: fields, current_epoch: n, expires_at_unix_s: integer | nil, revoked: boolean}}` (`fields` are complete `Elzoo.Principal.new/1` fields), `{:error, :not_found}` or `{:error, :unavailable}`. Anything else, or raising, is `:unavailable`.

A key is `<prefix>_<key_id>_<secret>`: `key_id` is 8..32 bytes of `[A-Za-z0-9]`, `secret` exactly 43 base64url characters without padding (32 bytes). `Elzoo.TokenVerify.verify_api_key(key, config, now_unix_s)` returns `{:ok, principal}` or `{:error, :malformed | :invalid_signature | :revoked | :expired | :unavailable}`. Order: shape (`:malformed`); `digest_key`; `lookup`; compare `HMAC-SHA-256(digest_key, secret)` with the stored digest by `:crypto.hash_equals/2`. An unknown key ID and a wrong secret both give `:invalid_signature`. Only after a match: `revoked: true` is `:revoked`; `expires_at_unix_s <= now_unix_s` is `:expired`; then build and check the principal as in JWT step 5 with its own `auth_epoch`, `:stale` giving `:revoked`.

## Secrecy

Failures are the fixed atoms only. The Piece emits no telemetry and no log. No token, key, secret or digest-key byte appears in a return value, a raised message or captured log output; Needs receive only `iss`/`sub` or `key_id`. The configs and the digest key keep a redacted `Inspect`.

## Acceptance

1. Valid EdDSA and RS256 tokens (keys generated in the tests with jose) and a valid API key give the expected principal, with JWT `auth_epoch` equal to `iat`.
2. `alg: none`; HS256 keyed with the RSA public PEM; an RS256 token naming an EdDSA key ID and the reverse; each forbidden header member, including a token signed by an attacker key carried in a `jwk` header; missing and unknown `kid`; a key removed from the set.
3. Tampered payload and signature; truncated token; 8,192 and 8,193 bytes; non-JSON and non-object claims; float, negative, string and out-of-range time claims.
4. Time edges with `leeway_s` 0 and 300: `exp + leeway_s` equal to `now_unix_s` is expired and one more second passes; `iat` and `nbf` at and beyond `now_unix_s + leeway_s`.
5. Issuer differing only by a trailing slash or case; audience string mismatch; audience list without and with the configured value.
6. Revocation: `subject` returning `:revoked` and `:unknown_subject`; `current_epoch` above `iat` refused and equal passing; an API key with `revoked: true`, a raised epoch and a past expiry; refusals that precede the digest match do not reveal revocation or expiry.
7. Needs: raising, malformed and unavailable results give `:unavailable`; `subject` is not called when an earlier step fails, and `lookup` is not called when `digest_key` fails (count the calls).
8. API key shapes: wrong prefix, separators, bad base64url, short and long parts; an unknown key ID and a wrong secret give the same result.
9. Secrecy: for each refusal and Need failure above, assert the token or secret bytes appear nowhere in the result, any raised message or captured logs.
10. Config: a private JWK, a 2,047-bit RSA key, a duplicate `kid`, 17 keys, `leeway_s` 301 and a missing or extra option raise the fixed `ArgumentError`.
11. Negative controls: temporarily pass the header `alg` (or both algorithms) to `verify_strict` instead of the key's, and separately skip the issuer check; the tests must fail. Restore before the final gates.

Limits to state: no JWKS fetch or rotation, single-use `jti`, ES256, JWE or OIDC ceremony; key-ID lookup timing is not constant; jose behaviour is an upstream contract pinned at 1.11.13. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
