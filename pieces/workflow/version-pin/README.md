# workflow/version-pin

The recipe version and the tool sources that one Run keeps. `Elzoo.VersionPin`
is four pure functions over values the caller supplies: no process, clock,
storage, callback, log or telemetry. It does not check that a version exists,
is checked or is published; `state/recipe-store` and the host own that.

The pin captures, at Run start, the version of the pinned recipe and the source
set that the host built from that recipe and the tenant settings read then. No
model, tool or person adds a source. A change of settings reaches the next
Run, not this one. An explicit change of the pinned version does not change the
captured set. The tool lists of known sources may change.

## `new(version, sources)`

Returns `{:ok, pin}` or `{:error, :invalid_input}`. `version` is a package
identity: the text `recipe-package-v1:sha256:` followed by 64 lowercase hex
characters (89 bytes). `sources` is the operand of
`Elzoo.ToolRegistry.snapshot/1`, and `snapshot/1` must accept it; each refusal
is `:invalid_input`. The pin keeps the version and, for each source, only `id`,
`kind` and `callable`; it keeps no tool list and no settings. The pin is opaque
plain data.

`version(pin)` returns the pinned identity. `sources(pin)` returns the captured
`[%{"id", "kind", "callable"}]` in the order given.

## `step(pin, input)`

Always `{:Transition, pin, {:some, result}}`.

| Input | Result | The pin |
| --- | --- | --- |
| `{:change_version, identity}` | `{:changed, old, identity}`; `:unchanged` when it is the pinned identity | holds `identity`; same source set |
| `{:published, identity}` | `:unchanged` | the same |
| `:settings_changed` | `:unchanged` | the same |
| `{:listing, source_id}` | `:known_source` when the set holds `source_id`, else `{:refused, :outside_source}` | the same |
| `{:add_source, term}`, any term | `{:refused, :source_set_closed}` | the same |
| anything else | `{:refused, :invalid_input}` | the same |

The operand is checked first: `{:change_version, x}` and `{:published, x}` with
an `x` that is not an identity, and `{:listing, x}` with an `x` that is not a
source ID (1 to 32 bytes of `[a-zA-Z0-9_-]`, the rule of
`workflow/tool-registry`), are `{:refused, :invalid_input}`. After any sequence
of inputs the source set equals the set of `new/2`.

`{:change_version, identity}` is the one explicit input. The host gives it only
for an action of an authorised operator, never from the content of a model, a
tool or a message. `{:published, _}` reports that the tenant published another
version: a running Run keeps its own.

Elixir checks the operands and classifies the input into a closed set; the
Cure decision maps the class to the result and to the next version and source
set, and Elixir only maps that result back to the terms above.

## Grounding

- Proof: the Cure laws `publish_keeps_version`,
  `only_explicit_change_changes_version` and `source_set_is_fixed`, checked by
  Cure over every version and source list, for the input classes that Elixir
  supplies. The operand checks and the classification are not covered.
- Type: pinned Cure checks the table and the totality of its functions; the
  source audit reports no axiom, hole or unproved-total definition.
- Test: `mix test pieces/workflow/version-pin/test` runs the groups
  `pin_at_start`, `publish_changes_no_running_run`, `explicit_change_only`,
  `settings_affect_next_run`, `source_set_closed` and `total_and_redacted`, the
  law/audit and the checked example `examples/version_pin.exs`. Two negative
  controls: a published input that changes the version, and an add-source
  input that adds a member; the matching law and groups fail. These are finite
  scenarios.
- Upstream: pinned Cure and Elixir; `Elzoo.ToolRegistry.snapshot/1` is reused
  unchanged.

## Needs and limits

Needs: a host that builds the source list truthfully at Run start, keeps the
pin in the durable state of the Run, asks `{:listing, id}` before it takes a
new tool listing of a source, starts a model graph or a tool only from a known
source, and gives `{:change_version, _}` only on an authorised, recorded action
with an identity that `state/recipe-store` holds as checked.

Limits: no check that a version exists, is checked or is published; no
operator check; no tool lists, which may change during the Run; no I/O, clock,
process or storage. Bounds: those of `snapshot/1` for the sources and 89 bytes
for an identity. Reasons: `:invalid_input`, `:outside_source`,
`:source_set_closed`. No input fragment appears in an error, a result, a log or
a telemetry event. Telemetry, Config and Control are not applicable.

Modules are application-owned under `Elzoo.VersionPin` and
`Cure.Elzoo.VersionPin`. Apache-2.0; direct dependency `workflow/tool-registry`;
no new dependency or pin.
