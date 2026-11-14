# runtime/lua-binding

`Elzoo.LuaBinding` declares the module functions that a recipe may call from
Lua, and checks each call. A host module offers functions; each has a
manifest (name, version, description, schema of its arguments and of its
result, cost, permissions). A recipe declares the functions that it uses. This
Piece resolves the declaration against the manifests that the caller
supplies, checks the arguments of a call before the call and the result
before it returns to Lua, and gives the two things that other Pieces need:
the names for the sandbox and one tool source for the registry. It is pure:
it calls no function of a module, runs no Lua and discovers nothing at run
time. Ready `core/payload-schema` and `workflow/tool-registry` are reused
unchanged.

## Interface and Contract

A **manifest** is a string-keyed map with exactly `"name"` (a binding name,
`[a-z][a-z0-9_]{0,63}` over the whole binary), `"version"` (an integer from 1
to 2^31-1), `"description"` (UTF-8 text of 1 to 1,024 bytes), `"arguments"`
and `"result"` (each exactly `"port"` and `"schema"`, the operands of
`Elzoo.PayloadSchema.build/2`, with direction `input` for the arguments and
`output` for the result), `"cost"` (exactly `"unit"`, UTF-8 text of 1 to 128
bytes, and `"estimate"`, an integer from 1 to 2^53) and `"permissions"` (at
most 64 unique UTF-8 strings of 1 to 128 bytes). The `arguments` schema must
have `"type": "object"` and `"additionalProperties": false`.

A **declaration** is a list of at most 64 exact maps `%{"name" => name,
"version" => version}` with unique names.

- `resolve(declaration, manifests)`: `{:ok, bindings}` or `{:refused,
  reasons}`. Each declared function resolves or has one reason, and all of
  them are given as `%{name:, code:}`, sorted by name then code:
  `:unknown_function` (no manifest has the name), `:wrong_version` (the name
  has manifests, none with the version), `:invalid_manifest` (the manifest of
  that name and version is not in the form above, has an extra or missing key,
  or one of its schemas is refused by `PayloadSchema.build/2`). Several
  versions of one name among the manifests are legal.
  `{:error, :invalid_input}` is given for a malformed declaration (a name
  twice too), a `manifests` value that is not a list of at most 256 maps, a
  manifest whose `name` is not a binding name or whose `version` is not an
  integer in range (these two members are read of every manifest, to match
  it), two manifests with one name and version, and each bound plus 1. Nothing
  else of a manifest that no declaration names is read.
- `names(bindings)`: the declared names, sorted; the `names` operand of a
  sandbox request.
- `identity(bindings)`: `"lua-binding-v1:sha256:"` and 64 lowercase hex
  characters, the SHA-256 of the canonical JSON (keys sorted by bytes) of the
  resolved manifests sorted by name. A change of any member of a resolved
  manifest changes it; an unresolved manifest does not. The caller records it
  with a run of a Lua tool.
- `check_arguments(bindings, name, arguments)` and `check_result(bindings,
  name, result)`: `:ok`, `{:refused, %{name: name, violations: [%{path:,
  code:}]}}` or `{:error, :unknown_function}`. The violations of
  `PayloadSchema.check/3` come unchanged (path segments: `:key` for a member,
  an integer for an array position; the member name is never given). Any other
  error of `check/3` (`:too_large`, `:too_deep`, `:invalid_payload`,
  `:validation_failed`) is one entry `%{path: [], code: reason}`. The order of
  violations is not fixed. A violation holds a path and a code, never a value.
- `cost(bindings, name)`: `{:ok, %{"unit", "estimate"}}` or `{:error,
  :unknown_function}`. `permissions(bindings)`: the sorted unique union of the
  permissions of the resolved functions.
- `source(bindings, id)`: `{:ok, source}` or `{:error, :invalid_input}`; one
  tool-registry source with the `id` (1 to 32 bytes of `[a-zA-Z0-9_-]`),
  `"kind": "other"`, `"callable": "adapter"` and one descriptor for each
  resolved function (`name`, `description` of the manifest, `input_schema` the
  `arguments` schema, `annotations` empty, `trust` `"untrusted"`). It calls
  `ToolRegistry.snapshot/1` itself; any refusal is `:invalid_input`. The
  caller puts the source into the source set of its Run and binds each alias to
  the real Adapter of the module.

A value that is not bindings of `resolve/2` is `{:error, :invalid_input}` for
every other function. No function takes or returns a secret, and no reason,
error or log holds an argument or a result value. The module has no `Logger`
call. The source holds the descriptions of the manifests, as the registry
needs them.

Bindings are the plain term `{:LuaBinding, entries}`: each resolved manifest as
given with its two checked schemas. A pattern can keep it in its state; a value
not made by `resolve/2` is outside the Contract.

Fixed bounds: 64 declared functions, 256 manifests, 64 permissions for each
function, 1,024 bytes of description; the bounds of `core/payload-schema` for
each schema.

## Needs and Limits

Needs: truthful manifests from the host, one for each function that a module
really offers, with schemas that the host approved; an Adapter binding for each
alias of the source; a caller that checks the arguments before it dispatches a
call and the result before it records it for the replay. For
`workflow/recipe-check` the caller puts, for each alias, the permissions of the
manifest into `tool_requirements` (`%{alias => %{"needs" => [], "permissions"
=> permissions}}`) and the estimate of the manifest into the cost entry of each
`tool` node that names the alias; the unit of the manifest must equal the unit
of that check.

Limits: no call, no Lua, no registry of modules and no discovery. A schema
check says that a value has the declared form, not that a call is allowed or
that it succeeded. The cost is an estimate that the manifest states. The
identity is stable for the pinned Jason and OTP; it is not RFC 8785. The
Piece does not depend on `runtime/lua-sandbox`: the binding-name form is the
only thing they share, and the group `names_fit_the_sandbox` shows that the
forms agree. Telemetry, Config and Control are not applicable: pure functions
over intrinsic operands.

## Grounding

- Proof: none; no Cure law is selected. The classification of a declared name
  (unknown, wrong version, invalid, resolved) is a restatement of lookups, not
  a pure decision with a law worth proving.
- Type: none; no Cure type check applies to this Piece. Elixir typespecs would
  be documentation only.
- Test: `mix test pieces/runtime/lua-binding/test` runs seven named groups:
  `resolve_at_load`, `arguments_located`, `results_checked_before_return`,
  `identity_changes_with_the_manifest`, `registry_source`,
  `names_fit_the_sandbox`, `bounds_and_redaction`. Two temporary negative
  controls (accept a wrong version; skip the result check) make the groups
  `resolve_at_load` and `results_checked_before_return` fail. Finite
  scenarios, not a universal proof.
- Monitor: none.
- Upstream: JSV 0.27.0 through `core/payload-schema`; `workflow/tool-registry`
  for the source form; Jason 1.4.5 for the canonical encoding; SHA-256 of OTP
  `:crypto`; pinned Elixir.
- Assumption: the Needs above; the manifests are the host's statement.
- Example: `examples/elzoo/lua_binding.exs` resolves two functions, builds the
  registry source, resolves and checks an alias, refuses a wrong argument and a
  wrong result, and reads the cost; the group `bounds_and_redaction` runs it.

The module is application-owned under `Elzoo.LuaBinding`; redistributors rename
it and the `:LuaBinding` tag. Apache-2.0; no new dependency or pin.
