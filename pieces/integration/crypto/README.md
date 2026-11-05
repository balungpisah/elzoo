# integration/crypto

Use OTP SHA-256 directly; a published abc vector grounds this usage.

## Use

:crypto.hash(:sha256, bytes). Run mix run examples/elzoo/hash.exs. Reuse upstream crypto; do not write your own primitives.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir, otp

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/crypto_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- This recipe covers hashing only, not passwords, encryption, TLS, key handling or cryptographic soundness.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
