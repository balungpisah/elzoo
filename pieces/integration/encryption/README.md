# integration/encryption

Seal records under a versioned per-subject key so that destroying the key
erases them (ELZ-273, [issue #624](https://github.com/balungpisah/elzoo/issues/624)).
One narrow Adapter over OTP 29 `:crypto`: AES-256-GCM only, one layer under the
per-subject key, no wrapped data keys, no new provider and no custom primitive.
The Level 3 `state/retention-erasure` holds one key per subject or tenant;
destroying it makes every envelope under it unreadable (crypto-shredding). This
Piece owns neither the key store nor key destruction.

## Envelope

All integers big-endian:

    "EZE1" | id_len::8 | key_id (id_len bytes) | version::64 | nonce (12 bytes) | ciphertext | tag (16 bytes)

The AEAD associated data is the header (`"EZE1"` through `version`) followed by
the caller's `aad`. The header is self-delimiting, so the concatenation is
unambiguous, and a changed key ID or version fails authentication. The nonce
is `:crypto.strong_rand_bytes(12)` on every seal. The tag is always 16 bytes
and the nonce always 12, fixed by the layout: OTP verifies only as many tag
bytes as it is given and accepts shorter IVs (see the drift tests).

## API

Keys are ready `integration/secrets` `%Elzoo.Secrets.Credential{}` values read
only through `Elzoo.Secrets.reveal/1`. The key version is the credential's
`version`. Like `reveal/1`, this Piece reads no clock and does not recheck
`expires_at_unix_ms`.

- `Elzoo.Encryption.seal(plaintext, aad, key_id, credential)` returns
  `{:ok, envelope}` or `{:error, :malformed | :key}`. `:malformed`: `plaintext`
  is not a binary of 0..1,048,576 bytes, `aad` not a binary of 0..1,024 bytes,
  or `key_id` not 1..128 bytes of valid UTF-8 without C0 or C1 control
  characters (U+0000–U+001F, U+007F–U+009F). `:key`: not a `Credential`, a
  revealed value that is not exactly 32 bytes, or a `version` that is not an
  integer in 1..9,007,199,254,740,991. Inputs are checked before the key, and
  the key length before any `:crypto` call.
- `Elzoo.Encryption.open(envelope, aad, keys)` returns `{:ok, plaintext}` or
  `{:error, :malformed | :no_key | :unavailable | :invalid}`, in this order:
  1. Envelope layout and bounds, then `aad`: `:malformed`. The Need is not called.
  2. `keys.(key_id, version)`, called exactly once. `{:ok, credential}` with a
     32-byte value and `credential.version == version` goes on.
     `{:error, :not_found}` is `:no_key`: the shredded or never-created key.
     `{:error, :unavailable}`, any other result, a version mismatch, a wrong
     key size, a raise, a throw or an exit is `:unavailable`. A `keys` value
     that is not an arity-2 function is also `:unavailable` (not called).
  3. AES-256-GCM decryption: `:error` is `:invalid` (wrong key, wrong `aad`, or
     a tampered header, nonce, ciphertext or tag).
- `Elzoo.Encryption.key_ref(envelope)` returns
  `{:ok, %{key_id: key_id, version: version}}` or `{:error, :malformed}` by the
  same layout check, so a host can find envelopes to re-seal after rotation.
  Rotation is the host's open-then-seal.

Every function returns a tuple for every input. Errors are the fixed atoms and
never echo plaintext, key, `aad` or envelope bytes. No telemetry and no log.

## Host Needs and limits

The host's `keys` Need must look up the exact `(key_id, version)` and map a
destroyed key to `{:error, :not_found}`:

```elixir
keys = fn key_id, version ->
  case MyApp.KeyVault.fetch(key_id, version) do
    {:ok, value} -> {:ok, %Elzoo.Secrets.Credential{value: value, version: version, expires_at_unix_ms: 0}}
    :destroyed -> {:error, :not_found}
    _ -> {:error, :unavailable}
  end
end
```

`MyApp.KeyVault` is consumer-owned. Passing straight through
`Elzoo.Secrets.resolve/2` gives only the current version and `:missing`, which
this Piece reports as `:unavailable`, not `:no_key`.

Random 96-bit nonces bound one key version to at most 2^32 seals (NIST SP
800-38D). The Piece does not count seals; the host rotates. Limits: no key
store, key generation policy, destruction, KMS or HSM, wrapping of data keys,
streaming, ChaCha20-Poly1305, or memory erasure of keys or plaintext. A
failure inside `:crypto` itself (for example an exhausted entropy source) is
not translated. OpenSSL behaviour is an upstream contract of the pinned OTP
29.1.2 (OpenSSL 3.5); this Piece does not prove AES-GCM.

Telemetry, Config and Control are `not_applicable`: the algorithm, layout and
bounds are fixed, the credential and Need are per-call operands, and there is
no process.

## Evidence

`test/elzoo/encryption_test.exs`, one `describe` per acceptance group:

1. Round trip of 0, 1 and 1,048,576-byte plaintexts, 0 and 1,024-byte `aad`,
   1 and 128-byte key IDs and versions 1 and 2^53−1; `key_ref/1`; a format pin
   that splits the envelope by the layout and opens it with
   `:crypto.crypto_one_time_aead/7`; a credential from `Elzoo.Secrets.resolve/2`.
2. Integrity: key-ID byte `a`→`b`, version 1→2, a bit flip in nonce,
   ciphertext and tag, another `aad`, another key and the last byte removed
   are `:invalid` after one Need call; every single-bit flip is refused.
3. OTP drift: GCM test case 13 tag, a 15-byte tag accepted, a wrong AAD
   `:error`, an 8-byte IV accepted and a 31-byte key raising.
4. Shape refusals of `seal/4`, `open/3` and `key_ref/1`, one fault per case.
5. Needs: `:no_key`, crypto-shredding of subject A while B opens, and each
   `:unavailable` fault, with counted Need calls.
6. 10,000 seals give 10,000 distinct nonces (a sanity check, not a proof).
7. Every refusal is the exact fixed tuple, with no plaintext, key or `aad`
   bytes in the result or the captured log; arbitrary terms never raise; the
   compiled module imports only `:crypto`, `:erlang`, `Elzoo.Secrets` and `String`.

Negative controls (temporary edits, reverted): leaving the header out of the
AAD fails groups 1 and 2; a fixed nonce fails group 6; skipping the credential
version check fails group 5. Tests only: no Cure law is selected.

## Consumption

`mix elzoo.take integration/encryption --to <consumer>` copies this Piece and
`integration/secrets`. Add `:crypto` to `extra_applications`. Source is
Apache-2.0; see [consuming](../../../docs/consuming.md).
