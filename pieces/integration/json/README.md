# integration/json

Use Jason directly for JSON values and explicit encode/decode errors.

## Use

Jason.encode(value) and Jason.decode(binary) return {:ok, value} or {:error, exception}. Run mix run examples/elzoo/json.exs.

This directory is a source bundle. See [consumption instructions](../../../docs/consuming.md) for copying selected pieces into a project.

## Dependencies

- Pieces: none
- Providers: jason

## Grounding

- **test**: The named scenarios in this ExUnit file are executable evidence, not universal proofs. `test/elzoo/json_recipe_test.exs`
- **upstream**: Relies on the pinned provider implementation and public contract. https://hexdocs.pm/jason/1.4.5/Jason.html

## Limits

- JSON syntax is not domain-schema validation.
- No Cure compiler or Elzoo wrapper is required for this recipe.

Copied source is Apache-2.0. External packages retain their own licenses.
Evidence describes the recorded source bytes and selected scenarios. After
customization, rerun/adapt its checks; the receipt is provenance, not a proof
of your modified application.
