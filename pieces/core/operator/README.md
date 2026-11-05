# core/operator

Generic pure zero-or-one-output stateful composition; a dropped input preserves downstream state.

## Use

Call Cure compose(first, second, Joined{left: ..., right: ...}, input). Both operators return Transition(state, Option(output)); composition pairs their states.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: cure

## Grounding

- **proof**: Composing discard with any downstream operator produces no output. `cure/elzoo/composition.cure`
- **proof**: Composing discard with any downstream operator preserves downstream state. `cure/elzoo/composition.cure`
- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/composition.cure`
- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/composition_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://github.com/cure-lang/cure-lang/tree/a004c335cc4e9f2203ba6f51fc31e8540b66378d

## Limits

- No named/versioned port graph or fan-out.
- Elixir callers of erased BEAM functions must honor the transition tuple contract.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.

At the Elixir boundary, higher-order Cure operator arguments are curried:
`fn state -> fn input -> transition end end`. Exported Cure functions and
the OTP Unit MFA are called with their ordinary arity (for example step/2).

The copied composition test includes the Cure incompatible-connection negative
control and this source file's audit; it does not depend on the sample Assembly.
This checks Cure types, not arbitrary erased Elixir runtime values.
