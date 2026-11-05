# assembly/ingest-dedup-accumulate

An example assembly combines duplicate suppression, accumulation and optional threshold nesting; direct and OTP traces are compared.

## Use

Build messages with Elzoo.Runtime.message/4, then call fused/1, hopped/1, or nested/2. Copy the assembly and modify its operators/wiring for your application.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: core/operator, delivery/idempotency, runtime/unit
- Providers: cure, elixir, otp

## Grounding

- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/consumer.cure`
- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/core.cure`
- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/extension.cure`
- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/runtime_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://github.com/cure-lang/cure-lang/tree/a004c335cc4e9f2203ba6f51fc31e8540b66378d
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/elixir/1.20.4/
- **upstream**: Relies on the pinned provider implementation and public contract. https://www.erlang.org/doc/

## Limits

- An example, not a general wiring engine.
- Unbounded volatile history; synchronous hops; no durable or distributed equivalence.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
