# ELZ-170 — The recipe version and source set that a Run keeps

## Scope and reuse

- Dependencies: ELZ-033, ELZ-002, ELZ-136, ELZ-164
- Output: `workflow/version-pin`, one public module `Elzoo.VersionPin`; release V1B; RC-65 version-pin portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/version-pin/**` and its index/generated changes under AGENTS.md section 3.

Coordinator decision, 2026-11-14: RC-65 is published as two tasks. This task
is the pure rule of which recipe version and which tool sources a Run uses.
`state/recipe-store` is a separate task; this Piece does not call it.

Owner decision, 2026-11-12 (RC-65 and RC-56): the pin captures the source set
of the Run at its start, from the pinned recipe and the tenant settings read
then. No model, tool or person adds a source. A change of settings affects
the next Run. An explicit change of the pinned version does not change the
captured set. The tool lists of known sources may change. A listing of an
outside source is refused and changes nothing.

One pure rule. Nothing executes and nothing is stored. Implement only the
named acceptance groups below. Add no store, no registry, no settings check,
no options, behaviours or hooks. Change no ready Piece, shared source, pin or
CI file. No fixtures directory is needed: use small literal values in tests.

Facts checked on main:

- `domain/recipe-package` (ELZ-164): the identity of a package is the text
  `recipe-package-v1:sha256:` followed by 64 lowercase hex characters.
- `workflow/tool-registry` (ELZ-136): a source is exactly `{"id", "kind",
  "callable", "tools"}`; `id` is 1 to 32 bytes of `[a-zA-Z0-9_-]`; `kind` is
  `pinned_skill`, `host_listing` or `other`; `callable` is `adapter` or
  `nested`. `refresh/3` changes the listing of a known source and refuses an
  unknown one. `snapshot/1` refuses more than 64 tools.
- `core/operator` (ELZ-002): a step gives `{:Transition, state, :none |
  {:some, output}}`.

## Interface: `Elzoo.VersionPin`

`new(version, sources)` returns `{:ok, pin}` or `{:error, :invalid_input}`.
`version` is a package identity in the form above. `sources` is the source
list that the host built at Run start from the pinned recipe and the tenant
settings: the operand of `ToolRegistry.snapshot/1`. `new/2` requires that
`ToolRegistry.snapshot(sources)` gives `{:ok, _}`; any refusal is
`:invalid_input`. The pin keeps the version and, for each source, only `id`,
`kind` and `callable`. It keeps no tool list and no settings.

`version(pin)` returns the pinned identity. `sources(pin)` returns the
captured `[%{"id", "kind", "callable"}]` in the order given.

`step(pin, input)` returns `{:Transition, pin, {:some, result}}`. The pin is
opaque plain data. Inputs and results:

| Input | Result | The pin |
| --- | --- | --- |
| `{:change_version, identity}` | `{:changed, old, identity}`; `:unchanged` when it is the pinned identity | holds `identity`; the source set is the same |
| `{:published, identity}` | `:unchanged` | the same |
| `:settings_changed` | `:unchanged` | the same |
| `{:listing, source_id}` | `:known_source` when the set holds `source_id`, else `{:refused, :outside_source}` | the same |
| `{:add_source, term}`, for every term | `{:refused, :source_set_closed}` | the same |
| anything else | `{:refused, :invalid_input}` | the same |

The operand is checked before the row applies: `{:change_version, x}` and
`{:published, x}` with an `x` that is not an identity in the form above, and
`{:listing, x}` with an `x` that is not a source ID in the form of ELZ-136,
are `{:refused, :invalid_input}`.

`{:change_version, identity}` is the one explicit input. The host gives it
only for an action of an authorised operator, never from the content of a
model, a tool or a message. `{:published, _}` reports that the tenant
published another version: a running Run keeps its own.

After any sequence of inputs the source set equals the set of `new/2`: same
members, same order, same kind and callable of each.

Cure owns the decision. Write the step as a total Cure function and prove at
least: `publish_keeps_version` (a published input never changes the pinned
version), `only_explicit_change_changes_version` (the version after a step
differs from the version before only for a change-version input) and
`source_set_is_fixed` (no input changes the membership of the set). The
Elixir module calls the Cure decision and does not decide again.

## Host Needs and Limits

Fixed bounds: those of `snapshot/1` for the sources; 89 bytes for an
identity. Reasons: `:invalid_input`, `:outside_source`, `:source_set_closed`.
No input fragment appears in an error, a log or a telemetry event.

Needs: a host that builds the source list truthfully at Run start, keeps the
pin in the durable state of the Run, asks `{:listing, id}` before it takes a
new tool listing of a source, starts a model graph or a tool only from a
known source, and gives `{:change_version, _}` only on an authorised,
recorded action with an identity that `state/recipe-store` holds as checked.

Limits: the pin does not check that a version exists, is checked or is
published, and it verifies no operator. It does not capture tool lists: the
list of a known source may change during the Run. No I/O, clock, process or
storage. A change of the platform that changes pattern state is not covered.
Telemetry, Config and Control are not applicable: pure functions over
intrinsic operands.

The manifest declares `kind: owned`, providers `cure` and `elixir`, and the
Piece dependency `workflow/tool-registry`.

## Named acceptance groups

1. **`pin_at_start`**: `new/2` with two sources gives the version and the
   two captured sources without their tool lists; each malformed identity
   and each refusal of `snapshot/1` is `:invalid_input`.
2. **`publish_changes_no_running_run`**: any number of `{:published, _}`
   inputs, with other identities and with the pinned one, leaves version and
   sources equal.
3. **`explicit_change_only`**: `{:change_version, new}` gives
   `{:changed, old, new}` and the new version; the same identity gives
   `:unchanged`; the source set is equal before and after; a malformed
   identity is refused and changes nothing.
4. **`settings_affect_next_run`**: `:settings_changed` changes nothing in a
   pin; a second `new/2` with other sources gives the other set.
5. **`source_set_closed`**: `{:add_source, _}` with a well-formed source and
   with a malformed one is refused; `{:listing, id}` is `:known_source` for
   each captured ID and `{:refused, :outside_source}` for another ID; the
   set is equal after each.
6. **`total_and_redacted`**: over a list of at least 40 inputs, well-formed
   and malformed, each result is one of the forms of the table; a sentinel
   text inside a refused input never appears in a result or a captured log;
   equal inputs give equal results. One small checked example covers the
   public API.

## Evidence and gate

Proof: the three named Cure laws, checked by Cure. Test: the six groups.
Negative controls: temporarily let `{:published, _}` change the version,
then temporarily let `{:add_source, _}` add a member; the corresponding law
or group must fail. Restore both before the final gate. Record assumptions
and test results separately.

Run `mix test pieces/workflow/version-pin/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

`state/recipe-store`, the published pointer, pin records, deletion, tenant
settings, the registry snapshot of a Run, the engine, and any change of a
ready Piece.
