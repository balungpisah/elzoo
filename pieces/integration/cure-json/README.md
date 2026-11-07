# integration/cure-json

Optional typed Cure-to-Jason string encoder with an Elixir input/error boundary.

## Use

Elzoo.JsonBoundary.encode(string) returns encoded JSON or an explicit validation/library error. This bridge is optional; integration/json alone does not pull in Cure.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: integration/json
- Providers: cure

## Grounding

- **type**: The pinned Cure compiler checks this source before emitting its BEAM. `cure/elzoo/adapter.cure`
- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/cure_json_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://github.com/balungpisah/cure-lang/tree/208248063d64e621782cd26dd30698ee42850a89
- **assumption**: The Jason extern signature accurately describes the upstream function; Elzoo does not prove its body. 

## Limits

- String encoding only; use Jason directly for general JSON.
- The foreign implementation and extern signature are assumptions, not local proofs.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
