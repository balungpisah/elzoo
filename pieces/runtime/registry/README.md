# runtime/registry

Use unique-key OTP Registry for local process name lookup.

## Use

Start Registry under your application supervisor, then Registry.register/3 and Registry.lookup/2. Choose an application-owned registry name.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir, otp

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/registry_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- Local names only; not durable identity, distributed discovery or an authorization boundary.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
