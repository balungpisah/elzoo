# delivery/idempotency

Volatile exact-key duplicate suppression by sender/incarnation/sequence.

## Use

In Cure, `use Elzoo.Idempotency`, then call `message(sender, incarnation,
sequence, value)` and `receiver(history, input)`. Start with an empty list.
The first occurrence emits the message; a repeated key emits `None()`.

From Elixir, use the generated BEAM module:

```elixir
input = :"Cure.Elzoo.Idempotency".message(1, 1, 0, 42)
{:Transition, history, {:some, ^input}} = :"Cure.Elzoo.Idempotency".receiver([], input)
{:Transition, ^history, :none} = :"Cure.Elzoo.Idempotency".receiver(history, input)
```

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: core/operator
- Providers: cure

## Grounding

- **proof**: The duplicate output decision emits nothing for any message. `cure/elzoo/idempotency.cure`
- **proof**: The fresh output decision preserves any message. `cure/elzoo/idempotency.cure`
- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/idempotency.cure`
- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/idempotency_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://github.com/cure-lang/cure-lang/tree/a004c335cc4e9f2203ba6f51fc31e8540b66378d

## Limits

- History is unbounded and discarded on restart.
- No bounded window, durability, exactly-once effects or cross-sender ordering.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.

The `duplicate_emits_nothing` and `fresh_preserves_message` proofs concern only
`emit` after its duplicate flag is supplied. `seen` and `receiver`, including
key detection, have finite test evidence, not those proofs. ELZ-005 will use
the separate `delivery/windowed-idempotency` ID and preserve this Contract.
