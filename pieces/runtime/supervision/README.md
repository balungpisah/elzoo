# runtime/supervision

Use OTP Supervisor and child specifications for lifecycle/restart.

## Use

Build child specs and call Supervisor.start_link(children, strategy: :one_for_one), normally from your Application. Run the self-contained supervision example.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: elixir, otp

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/supervision_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- The example uses volatile Agent state; restart resets it.
- No custom supervisor implementation or application-specific failure policy.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
