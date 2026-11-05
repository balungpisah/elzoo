# delivery/stream-combinators

Use Enum for finite transforms and Stream for lazy map/filter/take/scan.

## Use

Run mix run examples/elzoo/streams.exs. Compose ordinary Enum/Stream pipelines in your application.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/stream_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/

## Limits

- No Rx subscriptions, distributed backpressure or clock/window policy.
- Laziness does not by itself bound memory or side effects inside callbacks.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
