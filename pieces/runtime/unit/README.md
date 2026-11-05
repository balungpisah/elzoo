# runtime/unit

A GenServer serializes calls to a supplied module/function with private volatile state.

## Use

Elzoo.Unit.start_link({YourModule, :step, initial_state}); step must return {:Transition, next_state, :none | {:some, output}}. Use your own supervision tree.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir, otp

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/unit_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- Trusted transition tuples; named envelope validation is not implemented.
- GenServer.call is synchronous; no persistence, durable mailbox or OS isolation.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
