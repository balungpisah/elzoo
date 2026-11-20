# ELZ-273 — Seal records under a versioned per-subject key so that destroying the key erases them

- Phase: Wave 5 Level 2
- Dependencies: ELZ-033, ELZ-105
- Release: V1B
- Output: new `integration/encryption` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/encryption/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`integration/secrets`, `integration/crypto`), `mix.exs`, `mix.lock` or CI.

## Outcome and reuse boundary

One narrow Adapter over OTP 29 `:crypto` (OpenSSL 3.5 in the test image; no new provider, no custom primitive, no Ash). It seals a binary with AES-256-GCM under a caller-held 32-byte key that has an ID and a version. It opens such an envelope through an injected key Need. The key ID and version travel in the envelope header, which the AEAD authenticates. The Level 3 `state/retention-erasure` holds one key per subject or tenant, so destroying the key makes every envelope under it unreadable (crypto-shredding, owner decision of 2026-11-20). This Piece owns neither the key store nor key destruction.

Keys arrive as the ready `integration/secrets` `%Elzoo.Secrets.Credential{value, version, expires_at_unix_ms}` and are read only through `Elzoo.Secrets.reveal/1`. The key version is the credential's `version` (1..9,007,199,254,740,991 in that Piece). Like `reveal/1`, this Piece reads no clock and does not recheck `expires_at_unix_ms`; `Elzoo.Secrets.resolve/2` sampled it. Declare the provider `otp` (with application `crypto`, as `integration/crypto` does), `elixir` and the Piece dependency `integration/secrets`.

Observed at OTP 29.1.2 with `:crypto.crypto_one_time_aead/6,7`:

- AES-256-GCM with a zero key, a zero 96-bit IV and empty input gives tag `530f8afbc74536b9a963b4f1c4cb738b` (NIST GCM test case 13).
- Decryption with a wrong AAD returns `:error`.
- **Decryption with the tag truncated to 15 bytes still returns the plaintext.** OTP verifies only as many tag bytes as it is given.
- An 8-byte IV is accepted.
- A 31-byte key raises `ErlangError`.

So the Piece fixes the tag at 16 bytes and the nonce at 12 by layout, and checks key length before any `:crypto` call.

## Interface

Envelope layout, all integers big-endian:

    "EZE1" | id_len::8 | key_id (id_len bytes) | version::64 | nonce (12 bytes) | ciphertext | tag (16 bytes)

The AEAD's associated data is the header (`"EZE1"` through `version`) followed by the caller's `aad`. The header is self-delimiting, so the concatenation is unambiguous.

- `Elzoo.Encryption.seal(plaintext, aad, key_id, credential)` returns `{:ok, envelope}` or `{:error, :malformed | :key}`. `:malformed` covers `plaintext`, `aad` or `key_id` outside the bounds. `:key` is a `credential` that is not an `%Elzoo.Secrets.Credential{}`, whose revealed value is not exactly 32 bytes, or whose `version` is not an integer in 1..9,007,199,254,740,991. The nonce is `:crypto.strong_rand_bytes(12)` on every call.
- `Elzoo.Encryption.open(envelope, aad, keys)` returns `{:ok, plaintext}` or `{:error, reason}` with `reason` in `:malformed | :no_key | :unavailable | :invalid`. Order:
  1. Envelope layout and bounds, then `aad`, each giving `:malformed`.
  2. `keys` is an arity-2 Need, called exactly once as `keys.(key_id, version)`. `{:ok, credential}` with a 32-byte value and `credential.version == version` goes on. `{:error, :not_found}` is `:no_key`, the shredded or never-created key. `{:error, :unavailable}`, any other result, a version mismatch, a wrong key size, a raise, a throw or an exit is `:unavailable`.
  3. Decrypt. `:error` is `:invalid` (wrong key, wrong AAD, or a tampered header, nonce, ciphertext or tag).
- `Elzoo.Encryption.key_ref(envelope)` returns `{:ok, %{key_id: key_id, version: version}}` or `{:error, :malformed}`, by the same layout check, so a host can find envelopes to re-seal after rotation. Rotation is the host's open-then-seal.

## Bounds and invariants

- `plaintext`: a binary of 0..1,048,576 bytes; `aad`: 0..1,024 bytes; `key_id`: 1..128 bytes of valid UTF-8 without C0 or C1 control characters (the ELZ-267 text rule, so a subject or tenant ID fits). An envelope is at most 4 + 1 + 128 + 8 + 12 + 1,048,576 + 16 bytes. Its `version` is in 1..9,007,199,254,740,991.
- Every function returns a tuple for every input and never raises. Errors are the fixed atoms and never echo plaintext, key, AAD or envelope bytes. The Piece emits no telemetry and no log.
- Random 96-bit nonces bound one key version to at most 2^32 seals (NIST SP 800-38D). The Piece does not count seals; the host rotates.

## Acceptance

1. Round trip: plaintexts of 0, 1 and 1,048,576 bytes; `aad` of 0 and 1,024 bytes; key IDs of 1 and 128 bytes; versions 1 and 2^53−1. `key_ref/1` returns the ID and version. Format pin: the test splits the envelope by the documented layout, opens it with `:crypto.crypto_one_time_aead/7` and the documented AAD, and gets the plaintext.
2. Integrity, on an envelope of a non-empty plaintext under a key ID ending in `a`, with a Need that returns the original key for every reference and echoes the requested version on the credential. Each of these is `:invalid`: that last key-ID byte changed to `b`; version 1 changed to 2; one bit flipped in the nonce, the ciphertext and the tag; another `aad`; another 32-byte key; the last byte removed. An envelope one byte shorter than an empty-plaintext envelope is `:malformed`.
3. Drift tests that call `:crypto` directly: the test case 13 tag above; a 15-byte tag accepted on decryption (this is why the tag length is fixed by layout); a wrong AAD giving `:error`.
4. Shape, one fault per case: plaintext of 1,048,577 bytes, non-binary plaintext, `aad` of 1,025 bytes, and key IDs of 0 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085 are `:malformed` in `seal/4`. Credentials with 31- and 33-byte values, versions 0 and 2^53, and a plain map are `:key`. For `open/3` and `key_ref/1`: a non-binary, magic `EZE2`, `id_len` 0, `id_len` 129, a key ID with a control character, version 0, and ciphertext of 1,048,577 bytes are `:malformed`. A malformed `aad` with a valid envelope is `:malformed`.
5. Needs: `:not_found` is `:no_key`. Crypto-shredding: after the test's key map drops subject A's key, every envelope under A is `:no_key` while subject B's still opens. A raise, a throw, an exit, `{:ok, "raw"}`, a credential of the wrong version and a 31-byte value are each `:unavailable`. The Need is not called for any `:malformed` case and is called exactly once otherwise (count the calls).
6. 10,000 seals of one plaintext under one key give 10,000 distinct nonces. This is a sanity check, not a proof of randomness.
7. Secrecy and totality: for every refusal above, the plaintext, key and `aad` bytes appear in no result and no captured log, and no call raises.
8. Negative controls, one at a time: leave the header out of the AAD; use a fixed nonce; skip the credential version check. Each must make a case of groups 2, 5 or 6 fail. Restore before the final gates.

Limits to state: no key store, key generation policy, destruction, KMS or HSM, wrapping of data keys, streaming, ChaCha20-Poly1305, or memory erasure of keys or plaintext. OpenSSL behaviour is an upstream contract of the pinned OTP. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
