# runtime/lua-sandbox

`Elzoo.LuaSandbox` evaluates one pure Lua function of one plain input in a fresh
PUC **Lua 5.4.9** process outside the BEAM, under **policy version 1** (a fixed,
helper-free allow-list) and exact limits. The runtime is built from the installed
`lua_source` checkout (MIT, pinned to revision `312b9efaa1061c2c4cad08554dbc1351c3270eef`)
with plain `cc` and `ar` and an owned C host under `lib/elzoo/lua_sandbox/native/`.
No upstream source is copied into the Piece. Apache-2.0 for the Elzoo source.

## Contract

Evaluate one pure Lua function of one plain input in a fresh PUC Lua 5.4.9 process
outside the VM, started by a caller-held OTP Port from an executable that `build/2`
compiles from the installed pinned `lua_source` checkout and an owned C host, over
length-framed JSON, under helper-free policy version 1 with a canonical identity and
exact positive limits on counted steps, call depth, value bytes, live Lua memory and
wall time. A step, depth, size or unlisted-name stop is sticky and cannot be caught
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
  limits: %{steps: 10_000, call_depth: 8, value_bytes: 1_024, memory_bytes: 1_048_576, wall_ms: 500}
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
  `{:refused, reason}` or `{:host_outcome, reason}`. `runtime` names the Lua release,
  the upstream revision, the SHA-256 of the C host, the build options and the seed.
  Refusals: `invalid_request policy_mismatch invalid_result steps call_depth value_size
  unlisted_name lua_error`. Host outcomes: `memory wall_time process_exit protocol_error`.
  Errors contain no provider text, stack, source, input or path. Memory, wall time and
  abnormal exit are recorded inputs, never replay decisions.

## Request and limits

The request has exactly `source`, `input`, `policy` and `limits`. The source is UTF-8
Lua text (at most 65_536 bytes) that returns exactly one function; that function takes
the input and returns exactly one plain value (empty source, zero or several results
are `invalid_result`). Bytecode is never accepted. The policy must equal the built-in
identity; a mismatch is refused before any process starts and again by the host before
the Lua state exists.

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
and an empty one is an empty array. A fresh empty object cannot be built by a version 1
source (declared limit). Holes, mixed or non-string keys, functions, other userdata,
threads, cycles, non-finite numbers and invalid UTF-8 are `invalid_result`; objects are
encoded with sorted keys and floats with shortest round-trip digits. Sizes are checked
before any recursive traversal.

## Framing and process

One fresh process and Lua state per call; the calling process holds the Port, so no
service or pool exists. The request and the reply are each one frame: an unsigned
32-bit little-endian length followed by UTF-8 JSON, at most 1_048_576 bytes (OTP
`{packet, 4}` is not used). A zero or overbound length is decided before the body is
read. A partial header or body, EOF, invalid JSON, duplicate keys, trailing bytes or a
second reply are `protocol_error`. The child's stderr goes to `/dev/null`, its
environment is empty and no source or input is on argv. At the absolute deadline, on
any protocol error and when the caller dies, the child is killed by OS pid and its exit
report awaited (a host `setitimer` backstop and a stdin-hangup poll end it if the caller
cannot).

## Policy version 1

Fresh library and environment tables; strict lookup of a missing global, library field
or string method is `unlisted_name`. No helpers, bindings or callbacks. Granted names:

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

The **identity** is `policy-v1:sha256:<64 lowercase hex>` over the canonical JSON of the
descriptor (sorted keys, sorted qualified names, wrapper versions, numeric and iteration
rules, fixed maxima, framing version, empty helper and binding descriptors). An unknown
identity, including a future helper-enabled one, fails closed. The runtime identity
(release, revision, host SHA-256, build options, seed) is returned beside it; a changed
policy or build identity is not replay-compatible.

## The six acceptance groups

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
   with the descriptor; excluded names, helper names and `helper_echo` end in
   `unlisted_name`, directly and indirectly; no heap identity through `tostring` or
   `string.format`; host-side probes of non-plain inputs. Negative control: granting
   `print` fails the audit.
5. **`plain_data_and_protocol`** (`lua_sandbox_protocol_test.exs`): scalar round trips,
   empty array and object, depth 32 and 33, byte limits, non-plain results, every
   malformed frame, oversize output, child crash and private stderr text absent from
   every return value.
6. **`replay_and_survival`** (`lua_sandbox_replay_test.exs`): pure cases in 20 fresh
   calls and two fresh BEAM processes, memory and wall time recorded but not compared,
   a changed identity refused, the BEAM alive and the child reaped after adverse cases,
   no live child after caller death.

## Limits

* Not OS security isolation (above). No helpers, bindings, pooling, in-VM execution.
* **Private-layout maintenance limitation:** the allocator string guard reads
  `offsetof(TString, contents)` and the string allocation tag of the pinned internal
  `lobject.h`. The build refuses any revision other than the pinned bytes, but a new Lua
  revision needs a new review of that coupling before the pin moves.
* No cross-build replay claim. Memory, wall time and abnormal exit are host outcomes.
* A version 1 source cannot build a fresh empty object.
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
