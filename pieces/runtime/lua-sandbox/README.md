# runtime/lua-sandbox

`Elzoo.LuaSandbox` evaluates one pure Lua function of one plain input in a fresh
PUC **Lua 5.4.9** process outside the BEAM, under **policy version 1** (a fixed,
helper-free allow-list) and exact limits. The runtime is built from the installed
`lua_source` checkout (MIT, pinned to revision `312b9efaa1061c2c4cad08554dbc1351c3270eef`)
with plain `cc` and `ar` and an owned C host under `lib/elzoo/lua_sandbox/native/`.
No upstream source is copied into the Piece. Apache-2.0 for the Elzoo source.

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

`build/2` is for the consumer's build or install step, not for each evaluation. Both
operands are trusted host paths, never Lua input. The build verifies the exact bytes
of the upstream files it reads (the 32 library sources and every header), compiles
them with the explicit recipe plus fixed defines for a constant hash seed and sort
pivot, archives them fresh, compiles the owned host with `-Werror` and returns
`{:error, :build_failed}` for a missing tool, a different revision, an output
directory inside the source, or any compiler error. It never writes into the source.

`run/2` returns `{:ok, ...}`, `{:refused, reason}` or `{:host_outcome, reason}`.
Refusals: `invalid_request policy_mismatch invalid_result steps call_depth value_size
unlisted_name lua_error`. Host outcomes: `memory wall_time process_exit protocol_error`.
Memory, wall time and abnormal exit are recorded inputs, never replay decisions.

The request has exactly `source input policy limits`; `limits` has exactly positive
integers `steps` (<= 1_000_000), `call_depth` (<= 64), `value_bytes` (<= 65_536),
`memory_bytes` (<= 16_777_216) and `wall_ms` (<= 1_000). The source is UTF-8 Lua text
(<= 65_536 bytes) that returns exactly one function taking the input and returning
exactly one plain value. Bytecode is never accepted. The policy must equal the
built-in identity: a mismatch is refused before any process starts.

## Plain data

`nil`, booleans, UTF-8 strings, signed 64-bit integers, finite floats, lists and
maps with string keys, nested at most 32 containers; each string and the canonical
encoding of the input and of the result is at most `value_bytes`. In Lua, null is
one light userdata sentinel (compare with `==`; `tostring` refuses it) and a single
`nil` result also encodes as null. A decoded array and a decoded object keep their
kind in a host-private record, so an empty array and an empty object stay distinct.
An unrecorded table with keys exactly `1..n` is an array, with only string keys an
object, and an empty one is an empty array. A fresh empty object cannot be built by
a version 1 source (declared limit). Holes, mixed or non-string keys, functions,
other userdata, cycles, non-finite numbers and invalid UTF-8 are `invalid_result`.

## Process and protocol

One fresh process and Lua state per call; the calling process holds the Port, so no
service or pool exists. The request and the reply are each one frame: an unsigned
32-bit little-endian length followed by UTF-8 JSON, at most 1_048_576 bytes. A zero or
overbound length is decided before the body is read. A partial header or body, EOF,
invalid JSON, duplicate keys, trailing bytes or a second reply are `protocol_error`.
The child's stderr is `/dev/null`, its environment is empty and no source or input
is on argv. At the absolute deadline, or on any protocol error, the caller kills the
child by OS pid and waits for its exit report: no child outlives `run/2`.

## Needs

`cc` and `ar` for the build, the installed `lua_source` checkout, an executable path,
the OS `kill` utility, a monotonic timer and an OS process. No ambient clock, random,
file, network or environment access is granted to Lua.

## Evidence

Tests under `test/elzoo/` cover the groups below with real processes and a real
compiler. They are finite observations, not a security proof.

* `native_build_and_copy`: fresh build, 42 from a pure function, missing tools,
  wrong revision and failed compile.
* `plain_data_and_protocol`: round trips, bounds, malformed frames, crash and stderr.
* Smoke tests for steps, call depth, value size, unlisted names, sticky `pcall`,
  memory and wall time. The full adversarial tests of the limits, the capability
  surface and replay follow with the later groups of the task.

Private-layout maintenance limitation: the string guard in the host reads
`offsetof(TString, contents)` and the allocation tag of strings from the checkout's
internal headers; the exact-byte check of the build makes a different revision a
refusal, and the coupling needs a new audit for each upstream change.
