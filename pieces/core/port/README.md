# core/port

Check declared output-to-input compatibility without executing either side.
This pure source bundle supplies a language-neutral descriptor and Cure
compatibility policy, with a small Elixir representation boundary.

## Interface and Contract

The exact string-keyed map is:

```elixir
output = %{"id" => "counter.total", "direction" => "output",
           "schema_id" => "example/count", "schema_version" => 1}
input = %{"id" => "threshold.count", "direction" => "input",
          "schema_id" => "example/count", "schema_version" => 1}
{:ok, true} = Elzoo.Port.compatible(output, input)
```

`id` and `schema_id` are nonempty UTF-8 strings, compared exactly (no Unicode
normalization). `direction` is `"input"` or `"output"`. `schema_version` is a
positive integer. IDs are scoped to their owning interface; connected IDs
need not match. Schema IDs name a caller-maintained behavioral/data Contract,
not an inferred Elixir, Ash or Cure type. Versions must match exactly: no
subtyping, wildcard, coercion or version negotiation. Different semantic
identities (Work Item, Run, Attempt; money and counts) must use different
schemas even when their underlying representations match.

The map has exactly four keys. Unknown fields and malformed representations
return `{:error, :invalid_shape}` from `decode/1`; valid representations are
translated to `{:Descriptor, {:String, id_codepoints}, {:String, direction_codepoints},
{:String, schema_codepoints}, schema_version}` and
validated in Cure. Invalid contents return `:invalid_id`, `:invalid_direction`,
`:invalid_schema_id` or `:invalid_schema_version` in field order. `decode/1`
returns `{:ok, record}` on success. `encode/1` translates an already validated
record and is not a validator for arbitrary BEAM terms.

`compatible/2` validates source then target, reporting decode failures as
`{:error, {:source | :target, reason}}`. It then requires output-to-input
direction, equal schema ID and equal version, in that order, returning
`{:error, :direction_mismatch | :schema_mismatch | :version_mismatch}` or
`{:ok, true}`. Direct Cure callers use `Elzoo.Port.Descriptor`, `validate` and
`compatible`; `compatible` rejects semantically invalid typed descriptors as
`:invalid_source` or `:invalid_target` before comparing them.

## Scope, reuse and ownership

This is the missing declaration policy for the P0 ingest/accumulate Assembly
and later request/routing selection. It reuses Cure's String/Result machinery;
it does not recreate an Ash schema/action framework. Plain Elixir/OTP and Ash
Adapters can declare these same maps, without introspection or an Ash dependency.
The checker owns no state, performs no I/O, executes no callback, and binds no
descriptor to a function. Matching declarations do not validate live payloads
or prove a foreign implementation honors them. ELZ-004 owns the first actual
runtime payload/ABI integration.

ELZ-003 owns delivery policy, Envelope fields, placement and common delivery
result/error/deadline shapes. They belong outside this exact descriptor, not
in extra map keys. ELZ-007 owns candidate identity/ranking metadata. Global
name uniqueness and schema registry maintenance remain caller responsibilities.

Telemetry, Config and Control are `not_applicable`: these are pure checks on
intrinsic operands, with no process, ambient settings or lifecycle to control.

## Grounding and consumption

The pinned Cure compiler checks the source types. `test/elzoo/port_test.exs`
tests matching and rejected declarations, map/record translation and the
owned-source audit. `examples/elzoo/port.exs` shows the public calls, and the
test "the checked example returns the documented result of each case"
evaluates it. These are finite tests and type checks; **no new universal
compatibility proof** is claimed. Cure/compiler/String implementation behavior
is upstream grounding. There is no monitored runtime claim.

`mix elzoo.take core/port --to ../my_app` copies only this Piece and Cure build
support. No root Elzoo.Application is needed. Tests travel with the source;
the repository also compiles/runs this selection in an independent consumer.
See [consuming](../../../docs/consuming.md) for setup and provenance limits.

The application owns the `Elzoo.Port` / `Cure.Elzoo.Port` namespace and must
load one coordinated revision per module. Redistributing libraries must rename
modules/imports/MFAs and deliberately rename or translate the erased public
`:Descriptor` tag. The copier performs no automatic isolation. A changed ready
behavioral Contract requires a new Piece ID. Source is Apache-2.0; upstream
licenses and pins are recorded separately.
