# ELZ-178 — Declared module functions for Lua, with checked arguments and results

## Scope and reuse

- Dependencies: ELZ-033, ELZ-022, ELZ-115, ELZ-136
- Output: `runtime/lua-binding`, one public module `Elzoo.LuaBinding`; release V1B; RC-62 binding portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/lua-binding/**` and its index/generated changes under AGENTS.md section 3.

Admit the binding portion of RC-62. A host module offers functions to
recipes. Each function has a manifest: a name, a version, a schema of its
arguments and of its result, a cost and the permissions that it needs. A
recipe declares which functions it uses. This Piece resolves the declaration
against the manifests that the caller supplies, checks the arguments of a
call before the call and the result before it returns to Lua, and gives the
two things that other Pieces need: the names for the sandbox (ELZ-177) and
one tool source for the registry (ELZ-136). It is pure. It calls no function
of a module, runs no Lua and discovers nothing at run time.

Implement only the acceptance groups below. Reuse `core/payload-schema` for
every schema and `workflow/tool-registry` for the source form, unchanged.
Add no code generation, no registry of modules, no process, no options,
behaviours or hooks. Edit no ready Piece, shared path, pin or CI file. No
fixtures directory is needed.

Facts checked on main (confirm each when you start; if one differs, stop and
ask):

- `core/payload-schema` (ELZ-115): `Elzoo.PayloadSchema.build(port, schema)`
  gives `{:ok, checked}` or `{:error, :invalid_port | :invalid_schema}`; the
  port is exactly `id`, `direction`, `schema_id`, `schema_version`.
  `check(checked, port, payload)` gives `:ok`,
  `{:error, {:violations, list}}` or `{:error, reason}` with a reason such
  as `:too_large`, `:too_deep`, `:invalid_payload` or `:validation_failed`.
  A violation is `%{path: segments, code: :schema_mismatch}`; at most 16 are
  given, in no fixed order. In a path every object member is the atom
  `:key` and an array position is its integer: a member name never appears.
  A missing member is reported at the path of its object. A member that the
  schema does not name is refused only when the schema says
  `additionalProperties: false`.
- `workflow/tool-registry` (ELZ-136): a source is exactly `{"id", "kind",
  "callable", "tools"}` with an `id` of 1 to 32 bytes of `[a-zA-Z0-9_-]`; a
  descriptor is exactly `{"trust": "untrusted", "name", "description",
  "annotations", "input_schema"}`; a name matches `[A-Za-z0-9_.-]{1,128}`;
  `snapshot/1` refuses more than 64 tools and two tools with one alias. The
  alias is `id <> "_" <> name` when that matches `[a-zA-Z0-9_-]{1,64}`, else
  a cut form with a hash of the id and the name. `resolve/2` takes an alias,
  and a resolved tool holds `source` (the id) and `tool` (the name).
  `tools/1` lists the aliases.
- No shared canonical-JSON function exists: `domain/recipe-package` has a
  private one (keys sorted by bytes, then `Jason`). Write a private one of
  the same form here.
- `workflow/budget` (ELZ-022): a unit is an opaque nonempty UTF-8 string.
- `runtime/lua-sandbox` after ELZ-177: a binding name matches
  `[a-z][a-z0-9_]{0,63}`, at most 64 names; a binding call has exactly one
  plain argument; the reply of a pending call holds `index`, `name` and
  `arguments`.

## Interface: `Elzoo.LuaBinding`

**A manifest** is a string-keyed map with exactly:

- `name`: a binding name in the form of ELZ-177.
- `version`: an integer from 1 to 2^31-1.
- `description`: valid UTF-8 text of 1 to 1,024 bytes.
- `arguments` and `result`: each exactly `{"port", "schema"}`, the operands
  of `PayloadSchema.build/2`, with the direction `input` for `arguments` and
  `output` for `result`. This Piece itself requires that the `arguments`
  schema has `"type": "object"` and `"additionalProperties": false`.
- `cost`: exactly `{"unit": valid UTF-8 text of 1 to 128 bytes, "estimate":
  integer from 1 to 2^53}`.
- `permissions`: a list of at most 64 unique valid UTF-8 strings of 1 to 128
  bytes.

**A declaration** is what a recipe states: a list of at most 64 exact maps
`{"name": name, "version": integer from 1 to 2^31-1}` with unique names.

`resolve(declaration, manifests)` returns `{:ok, bindings}` or
`{:refused, reasons}`. `manifests` is the list that the caller supplies, at
most 256. Every reason is `%{name: name, code: code}`, and all of them are
given, sorted by name then code:

| Code | When |
| --- | --- |
| `:unknown_function` | no manifest has the declared name |
| `:wrong_version` | no manifest has the declared name and version, and one or more have the name |
| `:invalid_manifest` | the manifest with the declared name and version is not in the form above, or one of its schemas is refused by `PayloadSchema.build/2` |

Each declared function has exactly one of: resolved, or one of the three
reasons. Several versions of one name among the manifests are legal.

`{:error, :invalid_input}` is given for: a malformed `declaration` (also a
name twice); a `manifests` value that is not a list of maps; a manifest
whose `name` is not a binding name or whose `version` is not an integer in
the range (these two members are read of every manifest, to match it); two
manifests with the same name and version; each bound plus 1. Nothing else
of a manifest that no declaration names is read, so a fault there changes
nothing. `bindings` is opaque plain data that only `resolve/2` makes; a
value from elsewhere is outside the Contract. Nothing is called: resolving
is a load-time step with no Effect.

`names(bindings)` returns the declared names, sorted: the `names` operand of
a sandbox request.

`identity(bindings)` returns `lua-binding-v1:sha256:` plus 64 lowercase hex
characters: the SHA-256 of the canonical JSON (keys sorted by bytes) of the
resolved manifests, sorted by name. A change of any member of any resolved
manifest changes it. The caller records it with a run of a Lua tool.

`check_arguments(bindings, name, arguments)` returns `:ok`,
`{:refused, %{name: name, violations: [%{path, code}]}}` or
`{:error, :unknown_function}` for a name that is not resolved. `arguments`
is the plain value of the pending call of the sandbox. For
`{:error, {:violations, list}}` of `PayloadSchema.check/3` the violations
are that list, unchanged. For each other error of `check/3` the violations
are one entry `%{path: [], code: reason}` with its reason. So a refusal
names the function and locates the fault by the structural path of
`core/payload-schema`: `:key` for a member and an integer for a position.
The name of a member is not given.

Coordinator decision, 2026-11-14: the brief of RC-62 says "the function and
field named". The ready `core/payload-schema` hides member names in every
path on purpose, and this Piece writes no second validator. The function
name and the structural path are the located reason.

`check_result(bindings, name, result)` is the same for the result schema.

`cost(bindings, name)` returns `{:ok, %{"unit", "estimate"}}` or
`{:error, :unknown_function}`. `permissions(bindings)` returns the sorted
union of the permissions of the resolved functions.

`source(bindings, id)` returns `{:ok, source}` or `{:error, :invalid_input}`:
one tool-registry source with the given `id` (1 to 32 bytes of
`[a-zA-Z0-9_-]`), `"kind": "other"`,
`"callable": "adapter"`, and one descriptor for each resolved function:
`name` the binding name, `description` of the manifest, `input_schema` the
`schema` of its `arguments`, `annotations` an empty object, `trust`
`"untrusted"`. The caller puts this source into the source set of its Run
and binds each alias to the real Adapter of the module. `source/2` calls
`ToolRegistry.snapshot([source])` itself: any refusal of it is
`{:error, :invalid_input}`.

No function of this Piece takes or returns a secret, and no reason, error or
log holds an argument or a result value: a violation holds a path and a
code.

## Host Needs and Limits

Fixed bounds: 64 declared functions, 256 manifests, 64 permissions for each
function, 1,024 bytes of description; the bounds of `core/payload-schema`
for each schema.

Needs: truthful manifests from the host, one for each function that a module
really offers, with schemas that the host approved; an Adapter binding for
each alias of the source; a caller that checks the arguments before it
dispatches a call and the result before it records it for the replay. For
`workflow/recipe-check` the caller puts, for each alias, the permissions of
the manifest into `tool_requirements` (`%{alias => %{"needs" => [],
"permissions" => permissions}}`) and the estimate of the manifest into the
cost entry of each `tool` node that names the alias; the unit of the
manifest must equal the unit of that check.

Limits: no call, no Lua, no registry of modules and no discovery. A schema
check says that a value has the declared form, not that a call is allowed or
that it succeeded. The cost is an estimate that the manifest states.
Telemetry, Config and Control are not applicable: pure functions over
intrinsic operands.

The manifest declares `kind: owned`, the providers that the reuse needs
(as `workflow/tool-registry` declares them for the same libraries), and
the Piece dependencies `core/payload-schema` and `workflow/tool-registry`.
It does not depend on `runtime/lua-sandbox`: the name form above is the only
thing they share, and group 6 shows that they agree.

## Named acceptance groups

1. **`resolve_at_load`**: a declaration of three functions against five
   manifests resolves; a missing function, a wrong version and a manifest
   with a refused schema give their reasons, all at once and in order; an
   undeclared manifest with a fault in a member other than `name` and
   `version` changes nothing; two versions of one name resolve the declared
   one; a declared manifest with an extra key `module` and one whose schema
   holds a function value are `:invalid_manifest`; an `arguments` schema
   that is not an object schema or allows other members is
   `:invalid_manifest`.
2. **`arguments_located`**: a member of a wrong type is refused with the
   function name and a violation `%{path: [:key], code: :schema_mismatch}`
   among the violations; a missing member, an extra member and an array
   where an object is declared each with one at `[]`; a wrong element of an
   array member with its integer position in the path; an argument over the
   size bound of `core/payload-schema` with one entry `%{path: [], code:
   :too_large}`; a valid value is `:ok`; an unresolved name is
   `:unknown_function`. Assert with `in`, not on the whole list.
3. **`results_checked_before_return`**: the same for `check_result/3`, with
   a result that the schema refuses and one that it accepts.
4. **`identity_changes_with_the_manifest`**: equal resolved sets give equal
   identities in any input order; a changed description, schema, cost,
   permission or version gives another identity; an unresolved manifest does
   not change it.
5. **`registry_source`**: `source/2` of three functions passes
   `ToolRegistry.snapshot/1`; for each `name` of `ToolRegistry.tools/1`,
   `resolve/2` is `{:resolved, tool}`, and `ToolRegistry.check/2` is `:ok`
   for arguments that `check_arguments/3` accepts; 64 functions pass and the
   declaration bound refuses 65; a function with a name of 64 characters gets
   a cut alias and still resolves; an `id` that the registry refuses is
   `:invalid_input`.
6. **`names_fit_the_sandbox`**: each name form that this Piece accepts
   matches `[a-z][a-z0-9_]{0,63}`, and each form that it refuses does not;
   `names/1` is sorted and unique. (No sandbox is run here.)
7. **`bounds_and_redaction`**: each bound and bound plus 1; each malformed
   operand is `:invalid_input`; a sentinel text inside an argument, a result
   and a manifest description never appears in a reason, an error or a
   captured log. `cost/2` gives the cost of the manifest and
   `permissions/1` the sorted union, and both refuse an unresolved name or
   value. Equal inputs give equal results. One small checked example covers
   the public API.

## Evidence and gate

Test: the seven groups; reused Piece claims stay scoped to their Contracts.
Cure owns a new pure decision when a meaningful law is selected; do not add a
Boolean restatement. Negative controls: temporarily accept a wrong version,
then temporarily skip the result check; groups 1 and 3 must fail. Restore
both before the final gate.

Run `mix test pieces/runtime/lua-binding/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

The sandbox, `workflow/lua-tool`, the engine, Adapters of modules, the
operations face of a module (`runtime/faces`), code generation, and any
change of a ready Piece.
