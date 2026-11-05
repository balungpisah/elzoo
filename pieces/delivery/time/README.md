# delivery/time

Use Process.send_after and cancellation references; feed elapsed/deadline events into pure decisions.

## Use

Run the timers example. Keep wall-clock reads and timer scheduling in the shell, passing time events to operators.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir, otp

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/time_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- Timer delivery is not an exact scheduling guarantee.
- Monotonic time is local to a runtime; durable/distributed deadlines need a separate contract.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
