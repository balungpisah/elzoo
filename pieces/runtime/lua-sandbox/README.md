# runtime/lua-sandbox

`Elzoo.LuaSandbox` evaluates one pure Lua function of one plain input in a fresh
PUC **Lua 5.4.9** process outside the BEAM, under **policy version 3** (a fixed
allow-list, ten safe helpers and the bindings mechanism) and exact limits. The runtime is built from the installed
`lua_source` checkout (MIT, pinned to revision `312b9efaa1061c2c4cad08554dbc1351c3270eef`)
with plain `cc` and `ar` and an owned C host under `lib/elzoo/lua_sandbox/native/`.
No upstream source is copied into the Piece. Apache-2.0 for the Elzoo source.

## Contract

Evaluate one pure Lua function of one plain input in a fresh PUC Lua 5.4.9 process
outside the VM, started by an OTP Port from an executable that `build/2`
compiles from the installed pinned `lua_source` checkout and an owned C host, over
length-framed JSON, under capability policy version 3, whose fixed allow-list of names
and safe helper set (ten C helpers under the global `helpers`, each version 1, for JSON
null and empty object, canonical JSON encode and decode, ASCII trim, plain split, UTF-8
code-point count and UTC time values that the caller passes in) has a canonical identity,
with exact positive limits on counted steps, call depth, value bytes, live Lua memory and
wall time. For each declared name a function `bindings.<name>` is answered by the sandbox
itself: in mode `data` it builds a data object, in mode `replay` it returns the result that
the caller recorded for that call and the first unrecorded call ends the run with a
pending-call reply. Helpers charge counted steps for their work and their limits are the same
sticky stops. A step, depth, size or unlisted-name stop is sticky and cannot be caught
or continued from Lua. A refusal is a fixed atom; memory, wall time, abnormal exit
and protocol failure are recorded host outcomes; the child is reaped on every return
path, including the death of the caller. The full Contract text is in `piece.json`.

**Not OS security isolation.** There is no container, seccomp, namespace, network or
filesystem confinement, and Port separation does not protect against a vulnerability
in the native runtime.

## Interface

```elixir
{:ok, executable} = Elzoo.LuaSandbox.build(lua_source_directory, build_directory)

%{identity: identity, descriptor: _} = Elzoo.LuaSandbox.policy()

Elzoo.LuaSandbox.run(executable, %{
  source: "return function(x) return x + 1 end",
  input: 41,
  policy: identity,
  limits: %{steps: 10_000, call_depth: 8, value_bytes: 1_024, memory_bytes: 1_048_576, wall_ms: 500},
  calls: %{mode: "none", names: [], recorded: []}
})
#=> {:ok, %{value: 42, identity: identity, runtime: %{...}}}
```

* `build/2` returns `{:ok, executable}` or `{:error, :build_failed}`. Both operands are
  trusted host paths, never Lua input. The build verifies the exact bytes of the upstream
  files it reads (the 32 library sources and every header), compiles them with the
  explicit recipe plus fixed defines for a constant hash seed and sort pivot, archives
  them fresh, compiles the owned host with `-Werror` and refuses a missing tool, a
  different revision, an output directory inside the source and any compiler error. It
  never writes into the source. It is for the consumer's build or install step, not for
  each evaluation.
* `policy/0` returns `%{identity: identity, descriptor: descriptor}`; the descriptor is
  immutable plain data.
* `run/2` returns `{:ok, %{value: value, identity: identity, runtime: runtime}}`,
  `{:refused, reason}`, `{:host_outcome, reason}` or, in mode `replay` only,
  `{:pending_call, %{index: k, name: name, arguments: plain}}`. `runtime` names the Lua
  release, the upstream revision, the SHA-256 of the C host, the build options and the seed.
  Refusals: `invalid_request policy_mismatch invalid_result steps call_depth value_size
  unlisted_name lua_error call_mismatch`. Host outcomes: `memory wall_time process_exit protocol_error`.
  Errors contain no provider text, stack, source, input or path. Memory, wall time and
  abnormal exit are recorded inputs, never replay decisions.

## Request and limits

The request has exactly `source`, `input`, `policy`, `limits` and `calls`. The source is UTF-8
Lua text (at most 65_536 bytes) that returns exactly one function; that function takes
the input and returns exactly one plain value (empty source, zero or several results
are `invalid_result`). Bytecode is never accepted. The policy must equal the built-in
identity (a `policy-v1:` or `policy-v2:` identity is refused as `policy_mismatch`); a mismatch is refused
before any process starts and again by the host before the Lua state exists.

`limits` has exactly these keys, positive integers, no defaults, inclusive maxima:

| Limit | Maximum | Meaning |
| --- | --- | --- |
| `steps` | 1_000_000 | counted VM instructions across the chunk and the function |
| `call_depth` | 64 | active Lua calls; tail calls do not accumulate; callbacks from C count |
| `value_bytes` | 65_536 | each string, and the encoded input and result |
| `memory_bytes` | 16_777_216 | live Lua allocator bytes including the baseline |
| `wall_ms` | 1_000 | absolute deadline held by the caller |

A budget below initialization is refused without running user code (`value_bytes` below
4 is `value_size`, `memory_bytes` below the baseline is a `memory` host outcome). Limits
are per-call operands, not ambient Config; there is no hot update.

## Plain data

`nil`, booleans, UTF-8 strings, signed 64-bit integers, finite floats, lists and maps
with string keys, nested at most 32 containers (33 refuses). In Lua the null value is
one light userdata sentinel (compare with `==`; `tostring` refuses it) and a single
`nil` result also encodes as null. A decoded array and a decoded object keep their kind
in a host-private record, so an empty array and an empty object stay distinct. An
unrecorded table with keys exactly `1..n` is an array, with only string keys an object,
and an empty one is an empty array. A source builds a fresh empty object with
`helpers.object()` and reaches null as `helpers.null`. Holes, mixed or non-string keys, functions, other userdata,
threads, cycles, non-finite numbers and invalid UTF-8 are `invalid_result`; objects are
encoded with sorted keys and floats with shortest round-trip digits. Sizes are checked
before any recursive traversal.

## Framing and process

One fresh process and Lua state per call; a short-lived owner process, not linked to the
caller, holds the Port for one call, so no service or pool exists. The request and the
reply are each one frame: an unsigned 32-bit little-endian length followed by UTF-8
JSON, at most 1_048_576 bytes (OTP `{packet, 4}` is not used). A zero or overbound
length is decided before the body is read. A partial header or body, EOF, invalid JSON,
duplicate keys, trailing bytes or a second reply are `protocol_error`. The child's
stderr goes to `/dev/null`, its environment is empty and no source or input is on argv.
The caller holds the absolute deadline. At the deadline, on any protocol error and when
the caller dies, the owner kills the child by OS pid and reaps it before `run/2`
returns. An exit of the Port, such as a write into a closed child input, is a host
outcome and never an exit signal to the caller, whose links, monitors, flags and mailbox
are unchanged (a host `setitimer` backstop and a stdin-hangup poll end the child if the
owner cannot).

## Policy version 3

Fresh library, `helpers`, `bindings` and environment tables; strict lookup of a missing
global, library field, helper, binding or string method is `unlisted_name`. No callbacks.
Granted names (the helpers and the bindings are in the next sections):

* globals `assert error ipairs pcall select tonumber tostring type`;
* `string.byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper`;
* `table.concat insert move pack remove sort unpack`;
* `math.abs acos asin atan ceil cos deg exp floor fmod log max min modf rad sin sqrt tan tointeger type ult`
  and the constants `math.huge math.maxinteger math.mininteger math.pi`.

Not granted: `pairs`, `next`, `coroutine`, `xpcall`, `load`, `require`, `package`,
`os`, `io`, `debug`, `print`, `collectgarbage`, raw and metatable functions, random
access, `dofile`. `tostring` accepts only scalar text, numbers, booleans and nil;
`string.format` refuses `%p` and a non-scalar `%s`. Wrappers (`pcall`, `tostring`,
`string.format`, and the allocating or dense-array functions) carry explicit versions
in the descriptor; dense-array operations refuse sparse or mixed tables.

The **identity** is `policy-v3:sha256:<64 lowercase hex>` over the canonical JSON of the
descriptor (sorted keys, sorted qualified names, wrapper versions, numeric and iteration
rules, fixed maxima, framing version, the ten sorted helper descriptors
`{"name", "version": 1}` and the bindings entry `{"mechanism_version": 1, "max_names": 64,
"max_recorded": 256}`). The names of a request are operands, not part of the identity: the
caller owns their identity. An unknown identity, including a `policy-v1:` or `policy-v2:`
one, fails closed as `policy_mismatch`. The runtime identity
(release, revision, host SHA-256, build options, seed) is returned beside it; a changed
policy or build identity is not replay-compatible.

## Policy version 3: helpers

A source reaches the helpers as fields of the global `helpers`, a fresh table of each
run with the same strict lookup as the libraries: `helpers.x` for a name that is not
listed is `unlisted_name`, and so are the bare names `json`, `text`, `time`, `clock`,
`now` and `helper_echo`. A source can assign a field of `helpers` in its own run; that
changes only that run. Every helper is a C function of the host that takes plain values
and gives plain values. It reads no clock, environment or file.

| Helper (each version 1) | Arguments and result | Step charge |
| --- | --- | --- |
| `helpers.null` | The constant JSON null of the host (not `nil`). | none |
| `helpers.object()` | A fresh empty table that encodes as a JSON object. | 1 |
| `helpers.json_encode(value)` | The canonical JSON text of a plain value (sorted keys, dense arrays, `null`, finite numbers). | each byte of text given back, each table entry visited, each byte of a string key |
| `helpers.json_decode(text)` | The plain value of one JSON document; `null` is `helpers.null`, an object is a table marked as an object. | each byte read, each byte of a string that it makes, each table entry made |
| `helpers.text_trim(text)` | The text without leading and trailing ASCII space, tab, line feed, carriage return, form feed and vertical tab. | each byte read and given back |
| `helpers.text_split(text, separator)` | A dense array of the parts between occurrences of the plain, non-empty `separator`; `n` occurrences give `n + 1` parts, empty parts kept. | each byte read and given back, 1 for each part, and `len(separator) - 1` for each candidate position that it compares |
| `helpers.text_utf8_len(text)` | The number of code points of valid UTF-8 text. | each byte read |
| `helpers.time_parts(unix_ms)` | For an integer of 0 to 253402300799999: an object table with the integers `year`, `month`, `day`, `hour`, `minute`, `second`, `millisecond` and `weekday` (1 Monday to 7 Sunday), UTC, proleptic Gregorian. | 8 |
| `helpers.time_unix_ms(parts)` | The inverse for a table with the seven integer fields `year` (1970 to 9999) to `millisecond` of a real date and time; `weekday` and other fields are not read. | 7 |
| `helpers.time_iso8601(unix_ms)` | The text `YYYY-MM-DDTHH:MM:SS.mmmZ` for the same range. | 24 |

* **Errors:** wrong arguments (no coercion: a number is not a string, `1.0` is not an
  integer) and bad data are an ordinary Lua error with a fixed message that holds no data
  (for example `helpers.text_split: empty separator`). `pcall` catches it; uncaught it is
  `lua_error`.
* **Limits are sticky stops:** a step, `value_bytes` or `memory_bytes` limit reached inside
  a helper is the existing `steps` or `value_size` refusal or `memory` host outcome, and a
  `pcall` around it does not continue. A text result over `value_bytes` is `value_size`.
* **JSON rules:** `json_decode` applies the rules of an input (duplicate keys, trailing
  bytes, invalid UTF-8 and nesting deeper than 32 containers are errors) and `json_encode`
  those of a result (a function, a cycle, mixed keys, a hole, a non-finite number and
  nesting deeper than 32 containers are errors); both refuse 33 nested containers in both
  directions. `json_decode(json_encode(v))` encodes to the same text. `json_encode` writes
  into an output buffer of `value_bytes` bytes of Lua memory per call, so `memory_bytes`
  counts it and an error frees it.
* **Time is an input:** no helper gives the current time; the caller puts milliseconds
  in the input.

## Policy version 3: bindings

`calls` is a plain map with exactly the keys `mode`, `names` and `recorded`:

| Key | Rule |
| --- | --- |
| `mode` | `"none"`, `"data"` or `"replay"`. |
| `names` | At most 64 unique strings that match `[a-z][a-z0-9_]{0,63}`; empty with mode `"none"`. |
| `recorded` | At most 256 maps with exactly `name` (one of `names`), `arguments` and `result` (plain values); empty with modes `"none"` and `"data"`. |

Another shape is `invalid_request`; the canonical JSON of each `arguments` and each `result`
is at most `value_bytes`, else `value_size`. This is decided before a process starts and again
by the host before the Lua state exists; in the frame `calls` is one more member with string
keys, so the host reads five members. Policy version 3 names only: it has no schema check of
arguments, no cost and no permission (`runtime/lua-binding` owns them).

With mode `"none"` the global `bindings` does not exist (`bindings` and `bindings.x` are
`unlisted_name`, as in version 2). With the other modes `bindings` is a fresh table with the
strict lookup of a library: `bindings.<name>` for a name of `names` is a function and every
other field is `unlisted_name`. A source can assign its fields in its own run only; one that
replaces `bindings.<name>` by its own value makes no binding call when it uses it.

A **binding function** takes exactly one value, the arguments of the call (`nil` is null).
No value, two values or a value that a result would refuse (a function, a cycle, mixed keys,
a hole, a non-finite number, depth 33) is an ordinary Lua error with a fixed message that
`pcall` catches; such a call gets no index. An argument whose canonical JSON is over
`value_bytes` is the sticky `value_size` stop. **Order inside one call:** one step for each
byte of the canonical JSON of the argument; then the mode rule; then, for a returned value,
one step for each byte of its canonical JSON. A `steps` limit reached while the argument is
charged is `steps`, not a pending call.

* **Mode `data`:** `bindings.<name>(arguments)` returns a fresh object with exactly
  `"binding"` (the name) and `"arguments"` (a copy of the value, null for `nil`). A binding
  call inside the arguments of another runs first. Nothing is recorded and the run continues;
  the reply is the usual `{:ok, _}`.
* **Mode `replay`:** the sandbox counts binding calls from 0 over the chunk and the function.
  Call `k < length(recorded)` must have the name and the arguments of `recorded[k]`; then it
  returns the plain `result`, else the run ends with the sticky refusal `call_mismatch`.
  Call `k == length(recorded)` ends the run with a sticky stop and the reply
  `{:pending_call, %{index: k, name: name, arguments: plain}}`: no later statement runs and
  `pcall` does not catch it. A function that returns one value after fewer calls than
  `length(recorded)` is `call_mismatch` (a record that the source did not ask for is a
  different run); an uncaught error is still `lua_error` and a wrong number of results is
  still `invalid_result`. A limit reached first wins over a pending call. The caller performs
  the pending call itself, records the result and runs the source again from the start.
* **Compare rule:** the host pushes the recorded argument as a Lua value and encodes it with
  its one canonical JSON writer, then compares the bytes with the canonical JSON of the
  argument of the call. Equal arguments in another key order are equal; `1` and `1.0`, and an
  empty array and an empty object, are different.
* **Four reply forms:** `{:ok, _}`, `{:refused, reason}` (with `call_mismatch` beside the
  existing reasons), `{:host_outcome, reason}` and `{:pending_call, call}`. The same request
  gives the same reply, so the replay claim of the Piece covers these modes too.

## The acceptance groups

Tests under `test/elzoo/` run with a real compiler and real processes. They are finite
observations of listed scenarios, not a proof and not a security claim.

1. **`native_build_and_copy`** (`lua_sandbox_build_test.exs`): fresh build from the
   installed checkout, 42 from a pure function, the output directory removed, no write
   into the source, missing compiler or archiver, wrong revision, extra header and a
   failed compile refuse. The same file runs in the isolated copied-consumer test.
2. **`counted_sticky_limits`** (`lua_sandbox_limits_test.exs`): exact boundary and
   boundary + 1 of counted steps and call depth with known sources, string and memory
   bombs, value size at the cap and cap + 1, initialization, parser and allocation
   failures. Negative controls: an off-by-one step comparison, and no scoped allocation
   cap.
3. **`no_catching_or_continuation`** (`lua_sandbox_sticky_test.exs`): each stop through
   nested `pcall`, handler errors, repeated catches and callbacks never yields a
   post-stop marker; `xpcall` and coroutines are unreachable; a stopped real child ends
   at the wall deadline. Negative control: disabling the sticky guard.
4. **`exact_capability_surface`** (`lua_sandbox_surface_test.exs`,
   `lua_sandbox_policy_test.exs`): enumeration, host audit and fixed-name probes agree
   with the descriptor; excluded names, unlisted helper names and `helper_echo` end in
   `unlisted_name`, directly and indirectly; no heap identity through `tostring` or
   `string.format`; host-side probes of non-plain inputs. Negative controls: granting
   `print` and granting one more helper field fail the audit.
5. **`plain_data_and_protocol`** (`lua_sandbox_protocol_test.exs`): scalar round trips,
   empty array and object, depth 32 and 33, byte limits, non-plain results, every
   malformed frame, oversize output, child crash and private stderr text absent from
   every return value.
6. **`replay_and_survival`** (`lua_sandbox_replay_test.exs`): pure cases in 20 fresh
   calls and two fresh BEAM processes, memory and wall time recorded but not compared,
   a changed identity refused, the BEAM alive and the child reaped after adverse cases,
   no live child after caller death.
7. **`policy_v3_identity`** (`lua_sandbox_helpers_test.exs`): the descriptor names version
   3 and the ten helpers, the identity has the prefix `policy-v3:sha256:` and equals the
   digest of the descriptor, a `policy-v1:` identity and an identity with one helper
   removed are `policy_mismatch`, and the audit, the descriptor and the probes agree on the
   helper names. Negative control: granting one more helper field fails the audit.
8. **`helpers_surface`** (`lua_sandbox_helpers_test.exs`): each listed helper is reachable;
   unlisted helper names, `json`, `text`, `time`, `clock`, `now` and `helper_echo` are
   `unlisted_name`; an assignment to `helpers` lasts one run; the metatable of `helpers` is
   not reachable.
9. **`json_round_trip`** (`lua_sandbox_helpers_test.exs`): every scalar type, `null`, empty
   and nested containers at depth 32; depth 33, a function, a cycle, mixed keys, a hole,
   a non-finite number, duplicate keys, trailing bytes and invalid UTF-8 are errors that
   `pcall` catches; a decode leaves a request input unchanged; 1,000 calls in one run
   give equal results.
10. **`helpers_are_bounded`** (`lua_sandbox_helpers_test.exs`): an encode over `value_bytes`,
    a split of 65,536 separator bytes under 10,000 steps and a decode loop near the bound
    each end in the named sticky stop that `pcall` does not continue; the step count of a
    helper call grows with its input. Negative controls: removing the `charge` calls of
    `text_split`, of `json_encode` and of `json_decode` (each fails this group).
11. **`text_helpers`** (`lua_sandbox_helpers_test.exs`): trim of each ASCII space character
    and of nothing else; split with a separator at the start, at the end, doubled, absent
    and empty; code points of ASCII, two-, three- and four-byte characters; each invalid
    UTF-8 form is an error.
12. **`time_values`** (`lua_sandbox_helpers_test.exs`): the boundary values, the weekday of
    five known dates, 10,000 inverse values, every out-of-range, fractional, missing or
    unreal input an error, the ISO text, no result changed between two runs. Negative
    control: a wrong leap-year rule.
13. **`replay_and_survival_with_helpers`** (`lua_sandbox_replay_test.exs`): 31 pure cases
    that use each helper, in 20 fresh calls and two fresh BEAM processes with equal
    values or the same refusal; after 7 adverse cases with a helper the BEAM is alive, the
    child is reaped and a next helper call succeeds.

The bindings add eight groups in `lua_sandbox_bindings_test.exs` (and 5 tests of the exact
pending reply of the Elixir decoder):

14. **`request_shape`** (14 tests): each malformed `calls`, and a request without it or with
    an extra key, is `invalid_request` and no source runs; an argument or a result over
    `value_bytes` is `value_size`; the bounds 64 and 256 are inclusive; a recorded argument
    and a recorded result at 32 nested containers replay and at 33 are `invalid_request`; the
    host accepts an input at 32 nested containers and refuses 33 to 36; the host refuses the
    same shapes in a raw frame; the identity is version 3 and a version 2 identity is
    `policy_mismatch`. Negative controls: the host `calls` check made to accept every shape,
    the Elixir mode rule made to accept names with mode `"none"`, and the host input depth
    check removed (each fails this group).
15. **`none_is_version_2_surface`** (2 tests): with mode `"none"`, `bindings` and
    `bindings.x` are `unlisted_name`, also inside `pcall`; the other modes change nothing else.
16. **`data_mode_builds_data`** (10 tests): two bindings build two objects in place; null,
    empty object and empty array stay distinct; the arguments are a copy; 1,000 calls record
    nothing; `bindings.unknown` is `unlisted_name`; wrong argument counts and a non-plain
    argument are errors that `pcall` catches; an argument over `value_bytes` is the
    `value_size` stop; each byte of an argument and of a returned value costs one step.
    Negative control: removing the charge of the argument bytes fails this group.
17. **`replay_in_order`** (4 tests): no record is the pending call 0, one record the pending
    call 1 (the source saw the result of call 0), two records the value; a call in the
    chunk is call 0; every plain result comes back as recorded.
18. **`replay_mismatch`** (8 tests): another name, one changed argument value and a record
    list longer than the calls of the source are each `call_mismatch`, and `pcall` does not
    catch them; arguments built in another insertion order, and a raw frame with the recorded
    keys in another order, are equal. Negative control: returning the recorded result without
    comparing the arguments fails this group.
19. **`pending_is_sticky`** (8 tests): a pending call inside `pcall`, a `table.sort`
    comparator and a `string.gsub` callback ends the run with the pending reply and no later
    marker; a `steps` limit reached before the call, or while its argument is charged, is
    `steps`; a call with a wrong argument gets no index. Negative control: letting a `pcall`
    catch the pending stop fails this group.
20. **`same_request_same_reply`** (4 tests): each case of groups 16 to 18 and the sticky cases
    of group 19 gives one reply in 20 fresh calls and in two fresh BEAM processes; after
    each case the BEAM is alive, no child of a unique executable copy is left and a next valid
    call succeeds.
21. **`no_callback_no_state`** (4 tests): the host audit lists no `bindings` name or field;
    fixed-name probes show `bindings` absent with mode `"none"` and a table of functions with
    the other two; a second identical request gives the identical reply and sees nothing of
    the first; a child that sends a second frame after the pending frame is `protocol_error`.

## Limits

* Not OS security isolation (above). No caller callback, module manifest, schema check of
  arguments, cost or permission (`runtime/lua-binding` owns them), recipe engine, in-VM
  execution or pooling.
* **Names only:** the sandbox takes the names of the bindings and nothing else about them. The
  caller records the results truthfully; the sandbox cannot tell a true result from a false one.
  There is no callback to the caller and no state between runs: a replay starts from the
  source each time.
* **No normalization, no clock:** the helpers do no Unicode normalization and no case mapping
  beyond the ASCII rules of `string.lower` and `string.upper` (they need Unicode data tables),
  and no helper reads a clock, a time zone or a locale. A time is an integer of milliseconds
  that the caller puts in the input, in 1970-01-01 to 9999-12-31 UTC, proleptic Gregorian.
* **Private-layout maintenance limitation:** the allocator string guard reads
  `offsetof(TString, contents)` and the string allocation tag of the pinned internal
  `lobject.h`. The build refuses any revision other than the pinned bytes, but a new Lua
  revision needs a new review of that coupling before the pin moves.
* No cross-build replay claim. Memory, wall time and abnormal exit are host outcomes.
* The C host assumes Linux (`-DLUA_USE_LINUX`, `poll`, `setitimer`, `/dev/null`).
* The consumer owns the production build and install; the build is not per evaluation.

## Needs

An executable built by `build/2` (needs `cc` and `ar` and the installed `lua_source`
checkout), an OS process spawn (a Port), the OS `kill` utility, and a monotonic timer.
No ambient clock, random, file, network or environment access is granted to Lua.

## Operations

* **Telemetry:** no event, log or measurement; no observation channel carries the
  source, input, result or a Lua message.
* **Config:** the five limits are per-call operands; no ambient Config, no hot update.
* **Control:** no independent Control API; a caller ends an evaluation by its own exit.

## Building as a consumer

Declare the source-only `lua_source` provider in your own project with
`compile: false, app: false` (the generated install instructions keep those options and
the pinned Git revision), copy this Piece's files, and call `build/2` once from your
build or install step with `Mix.Project.deps_paths()[:lua_source]` and a build directory
outside that checkout. `examples/elzoo/lua_sandbox.exs` shows the call and evaluates 42.
