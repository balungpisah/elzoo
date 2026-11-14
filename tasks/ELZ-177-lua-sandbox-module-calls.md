# ELZ-177 — The Lua sandbox carries module calls as data and as a replay

## Scope and reuse

- Dependencies: ELZ-033, ELZ-163, ELZ-174
- Output: none. This task changes the ready Piece `runtime/lua-sandbox` in place; the Piece ID stays. First portion of RC-62.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/lua-sandbox/**` and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, and the generated files).

`AGENTS.md` section 4: before the first release a ready Piece is extended in
place. RC-62 gives a recipe the declared functions of host modules. A Lua
source never calls the host. It gets, for each declared name, a function
`bindings.<name>` that the sandbox itself answers, in one of two ways:

- **Load time.** The recipe file runs once and returns plain data. A binding
  call builds data: it returns a value that says "this call", and nothing
  else happens. No Effect.
- **Run time.** A tool written in Lua runs from the start each time. A
  binding call returns the result that the caller recorded for that call, in
  order. The first call that has no recorded result ends the run, and the
  reply names it. The caller then performs that call as its own action,
  records the result and runs the source again.

So the sandbox needs no callback, no second process and no state between
runs. Which functions exist, their schemas and their costs are the work of
`runtime/lua-binding`; this task takes names only.

Facts to confirm on `main` when ELZ-174 is merged (this task is written
against the Piece as ELZ-163 and ELZ-174 define it; if the code differs, stop
and ask):

- A request has exactly `source`, `input`, `policy`, `limits`; the reply is
  `{:ok, _}`, `{:refused, reason}` or `{:host_outcome, reason}`.
- The descriptor has `"bindings" => %{}`; the identity prefix is a literal
  (`policy-v2:sha256:` after ELZ-174); `run/2` refuses every other identity.
- A missing global or library field is the sticky `unlisted_name`.
  `set_sticky` with `stop_raise` makes a stop that `pcall` cannot catch.
- The host turns a JSON value into a plain Lua value and back, with `null` as
  one light userdata and objects marked in a weak table; the canonical JSON
  writer sorts keys.

Implement only what is below. Add no callback to the caller, no module
manifest, no schema check of arguments, no cost, no permission, no second
host file and no state between runs. Edit no other Piece, shared path, pin or
CI file. No fixtures directory is needed.

## The request

A request has exactly the atom keys `source`, `input`, `policy`, `limits`
and `calls`. `calls` is a map with exactly the atom keys:

- `mode`: the string `"none"`, `"data"` or `"replay"`.
- `names`: a list of at most 64 unique strings, each matching
  `[a-z][a-z0-9_]{0,63}`. With mode `"none"` it must be empty.
- `recorded`: a list of at most 256 maps, each with exactly the atom keys
  `name` (a name of `names`), `arguments` and `result` (plain values). With
  the modes `"none"` and `"data"` it must be empty.

A `calls` in another shape is `invalid_request`. The canonical JSON of each
`arguments` and each `result` is at most `value_bytes`: a larger one is
`value_size`, as for `input` today, and a request over the frame bound is
refused as today. All of this is decided before any source runs. In the
frame, `calls` is one more member of the request object, with string keys;
the host then reads five members.

With mode `"none"` the global `bindings` does not exist: `bindings` and
`bindings.x` are `unlisted_name`, as today.

With the other modes `bindings` is a fresh table with the strict lookup of a
library: `bindings.<name>` for a name of `names` is a function, and every
other field is `unlisted_name`. As for a library table, a source can assign
its fields in its own run only.

A binding function takes exactly one value, the arguments of the call. A
`nil` argument is `null`. No argument, more than one argument, or a value
that a result would refuse (a function, a cycle, mixed keys, a hole, a
non-finite number, depth 33) is an ordinary Lua error with a fixed message,
as for a helper; such a call gets no index and is not a binding call for the
rules below. An argument whose canonical JSON is over `value_bytes` is the
sticky `value_size` stop, as for `helpers.json_encode`.

Order inside one call: the argument is encoded and one step is charged for
each byte of its canonical JSON; then the mode rule below applies; a value
that the call returns is charged one step for each byte of its canonical
JSON before it is returned. So a `steps` limit that is reached while the
argument is charged gives `steps`, not a pending call.

A source that replaces `bindings.<name>` by its own value makes no binding
call when it uses that value.

## Mode `data`

`bindings.<name>(arguments)` returns a fresh table marked as an object with
exactly `"binding"` (the name) and `"arguments"` (a copy of the plain value;
the null value for `nil`). A binding call inside the arguments of another
runs first, so its object is part of the outer arguments.
Nothing is recorded and the run continues. The source returns its plain data
as usual, with these objects wherever it put them. The reply is the usual
`{:ok, %{value, identity, runtime}}`.

## Mode `replay`

The sandbox counts binding calls from 0 over the chunk and the function.

- Call `k` with `k < length(recorded)`: the name and the canonical JSON of
  the arguments must equal those of `recorded[k]`. Then the function returns
  the plain value of `recorded[k].result`. If they differ, the run ends with
  the sticky refusal `call_mismatch`.
- Call `k` with `k == length(recorded)`: the run ends with a sticky stop,
  and the reply is `{:pending_call, %{index: k, name: name, arguments:
  plain}}`. No later statement of the source runs, and `pcall` does not catch
  it.
- A function that returns exactly one value after fewer than
  `length(recorded)` calls ends with `call_mismatch`, before the value is
  encoded: a record that the source did not ask for is a different run. An
  uncaught error is still `lua_error`, and a wrong number of results is
  still `invalid_result`.

`run/2` therefore returns one of four forms: `{:ok, _}`,
`{:refused, reason}` with the new reason `call_mismatch` beside the existing
ones, `{:host_outcome, reason}`, or `{:pending_call, call}`. A limit that is
reached first wins over a pending call: the stops stay sticky in the order
in which they happen.

Because every run starts from the same source, input and record, the same
request gives the same reply: the replay claim of the Piece covers these two
modes too.

Notes on the host as built, for the worker (confirm them in the code):

- The host has one canonical JSON writer, from a Lua value. Compare a
  recorded argument by pushing it as a Lua value and encoding it, or by an
  equal rule of your own that the tests of group 5 hold; say in the README
  which.
- The result buffer of the reply is static and is filled once at the end.
  Encode arguments during the run into a buffer of their own, never into
  the result buffer.
- The node arena of the request stays alive during the run, so a recorded
  result can be pushed from it when its call happens. The JSON helper of
  ELZ-174 must not reset or overwrite it; check how ELZ-174 did its decode.
- `reply_sticky` is the one exit of every sticky stop: the pending reply is
  one more case of it, with the index, the name and the encoded argument
  kept at stop time.
- The reply decoder of `Elzoo.LuaSandbox` accepts exact reply shapes and
  treats every other frame as `protocol_error`: add the pending shape and
  the reason `call_mismatch` there.

## Policy version 3

The descriptor has `"policy_version" => 3` and
`"bindings" => {"mechanism_version" => 1, "max_names" => 64,
"max_recorded" => 256}` (the two bounds are stated there and not in
`"bounds"`); the identity prefix is `policy-v3:sha256:`. The
names of a request are not part of the policy identity: they are operands,
and the caller (`runtime/lua-binding`) owns their identity. A `policy-v2:`
identity is `policy_mismatch`. Everything else of version 2 is unchanged.
Update each text of the Piece that names the policy version or says that
the Piece has no bindings (the moduledoc, the README, `piece.json`).

## Named acceptance groups

Keep every existing group green. An assertion that fixes policy version 2 or
the four-key request changes to version 3 and the five-key request (with
mode `"none"` where the test does not use bindings); name each such change
in the pull request body. The test helper of the Piece gets a `calls`
operand with the default mode `"none"`.

1. **`request_shape`**: each malformed `calls` (a missing key, an unknown
   mode, a bad name, a duplicate name, 65 names, 257 records, a record whose
   name is not listed, names or records with mode `"none"`, records with mode
   `"data"`) is `invalid_request`, a recorded argument or result whose
   canonical JSON is over `value_bytes` is `value_size`, and in each case no
   source runs; the policy identity is version 3 and a version 2 identity is
   `policy_mismatch`.
2. **`none_is_version_2_surface`**: with mode `"none"`, `bindings` and
   `bindings.x` are `unlisted_name`, and every existing surface test passes.
3. **`data_mode_builds_data`**: a source that calls two bindings and returns
   a table that holds their results gets `{:ok, value}` with the two
   `{"binding", "arguments"}` objects in place; calling a binding 1,000 times
   records nothing and has no effect outside the value; `bindings.unknown` is
   `unlisted_name`; wrong argument counts and a non-plain argument are errors
   that `pcall` catches.
4. **`replay_in_order`**: a source with two calls: with no record the reply
   is the pending call 0 with its name and arguments; with one record the
   reply is the pending call 1, and the source saw the recorded result of
   call 0 (it puts it in the arguments of call 1); with two records the
   reply is `{:ok, value}` and the value holds both results.
5. **`replay_mismatch`**: a record with another name, with one changed
   argument value, and a record list longer than the calls of the source are
   each `call_mismatch`, and none is caught by `pcall`. Equal arguments in
   another order are equal: the source builds its argument table in another
   insertion order than the record, and a raw frame (`raw_exchange/3`) gives
   a record with its keys in another order; both replay.
6. **`pending_is_sticky`**: a pending call inside `pcall`, inside a
   `table.sort` comparator and inside a `string.gsub` callback ends the run
   with the pending reply and no later marker; a `steps` limit that is
   reached before the call, and one that is reached while the argument of
   the call is charged, give `steps`, not a pending call; a call with a
   wrong argument inside `pcall` gets no index, and the next good call is
   call 0.
7. **`same_request_same_reply`**: each case of groups 3 to 5 in 20 fresh
   calls and two fresh BEAM processes gives the same reply; after each case
   the owning BEAM is alive, the child is reaped and a next valid call
   succeeds.
8. **`no_callback_no_state`**: the audit of the host (which takes no
   request) lists no `bindings`; fixed-name probes show `bindings` absent
   with mode `"none"` and present with the other two; a second identical
   request gives the identical reply and sees nothing of the first; a child
   that sends a second frame is `protocol_error`, as today.

## Evidence and gate

Test: the eight groups and the unchanged suite, as finite real-process
tests. The README and `piece.json` name the groups, the two modes, the
fourth reply form and the Limits (names only; no schema, cost or permission
here; the caller records results truthfully). Negative controls: temporarily
return the recorded result without comparing the arguments (group 5 must
fail), then temporarily let a `pcall` catch the pending stop (group 6 must
fail). Restore both before the final gate.

Run `mix test pieces/runtime/lua-sandbox/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff,
including extra features.

## Not in scope

`runtime/lua-binding`, `workflow/lua-tool`, manifests, schemas, costs,
permissions, the tool registry, the engine, a callback into the caller, and
any change of `lua_source` or its pin.
