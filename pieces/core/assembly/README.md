# core/assembly

Compose two declared one-input/one-output interfaces into an outer interface
that can be composed again. Execution reuses the unchanged `core/operator`
transition and `compose`; descriptor checking is a separate pre-execution step.

## Interface and Contract

An interface is exactly `%{"input" => input_port, "output" => output_port}`,
using [core/port](../port/README.md)'s descriptors without a second schema.
`Elzoo.Assembly.decode/1` validates both descriptors, their respective input
and output directions, and distinct IDs within this interface. It returns
`{:ok, {:Interface, input_record, output_record}}` or `{:error, reason}`.
Unknown/missing fields return `:invalid_shape`; invalid ports return
`{:input | :output, reason}`, wrong directions `:invalid_direction`, and
duplicate IDs `:duplicate_port_id`.

`Elzoo.Assembly.connect(first, second)` validates first then second and checks
`first.output -> second.input` using the Cure Port policy. On success it
returns `{:ok, %{"input" => first.input, "output" => second.output}}`, retaining
the exact outer declarations. The outer IDs must also differ. Choose
owner-scoped names before composing; no implicit renaming occurs. Validation
failures are `{:error, {:first | :second, reason}}`; connection failures use
core/port's mismatch reasons; outer collision returns `:duplicate_port_id`.
No function is called by this operation.

Cure callers use `Elzoo.Assembly.Interface`, `validate` and `connect` directly.
The latter rejects invalid typed interfaces as `:invalid_first` or
`:invalid_second`. Directly passing malformed erased tuples from Elixir is
outside that typed Contract; the map boundary is the supported translation.

## Execution and state

Use `Elzoo.Composition.compose(first, second, state, input)` from core/operator
for execution. Both operators have
`(state, input) -> Transition(next_state, Option(output))`. The caller owns
the state value and supplies the next state to the next invocation. `Joined`
holds each child's separate state; nesting pairs preserves this structure.
`None` drops the output and leaves downstream state untouched; `Some` invokes
the next operator once and returns its zero-or-one output. Child functions
must be pure and honor the declared state and payload types. This bundle adds
no state store, scheduling, serialization, persistence, concurrency control,
exception rollback or runtime callback sandbox. Invalid foreign function
returns and exceptions remain outside the pure transition Contract.

`test/elzoo/assembly_test.exs` contains an executable Cure count → threshold →
retain example with `Int -> Int -> Bool -> Bool` connections and nested state.
It also substitutes a Bool-to-Int connection and requires compilation failure.
The descriptor tests separately exercise those named schema relationships.
There is deliberately no assertion that a schema string proves a function's
Cure type, or that passing a descriptor check certifies a live payload.

## Boundary and reuse

The P0 Assembly needs a reusable outer interface; request/routing selection
can inspect the same descriptors later. Existing core/operator composition
already supplies the mechanism, so it is reused without behavior changes.
Only the missing pure interface decision is new Cure code. The Elixir module
translates representations; it adds no effectful runtime or Ash dependency.

ELZ-003 alone owns delivery, Envelope, placement and wiring checks. Fan-out,
arbitrary graph validation, required-route checks and runtime Adapter validation
are outside this subset. No root Elzoo.Application is required.
Telemetry, Config and Control are `not_applicable`: pure declaration operands,
no ambient configuration, observations or independent lifecycle.

## Grounding and consumption

`mix elzoo.take core/assembly --to ../my_app` selects this Piece, core/port and
core/operator. Tests travel with source. The repository checks this isolated
selection without the root Application or project modules, reusing only
upstream dependency code paths. This is not a fresh dependency-fetch test.

Cure type checking, positive/negative ExUnit checks and source audits ground
the named claims. The existing core/operator laws remain that Piece's evidence;
no new universal descriptor or composition theorem is claimed. Cure's pinned
compiler and record/Result erasure remain upstream contracts. No runtime
observations or foreign implementation guarantees are inferred.

Follow [consuming](../../../docs/consuming.md): application-owned namespaces,
one coordinated revision per module, and explicit module/import/MFA plus public
record-tag renaming/translation for redistributing libraries. `:Interface`,
`:Descriptor`, `:Transition` and `:Joined` erase without module isolation.
Changing ready behavior requires a new Piece ID and explicit consumer opt-in.
Elzoo-owned source is Apache-2.0; upstream licenses are separate.
