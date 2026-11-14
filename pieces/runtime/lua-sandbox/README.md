# runtime/lua-sandbox

`Elzoo.LuaSandbox` evaluates one pure Lua function of one plain input in a fresh
PUC **Lua 5.4.9** process outside the BEAM, under **policy version 2** (a fixed
allow-list plus ten safe helpers) and exact limits. The runtime is built from the installed
`lua_source` checkout (MIT, pinned to revision `312b9efaa1061c2c4cad08554dbc1351c3270eef`)
with plain `cc` and `ar` and an owned C host under `lib/elzoo/lua_sandbox/native/`.
No upstream source is copied into the Piece. Apache-2.0 for the Elzoo source.

## Contract

Evaluate one pure Lua function of one plain input in a fresh PUC Lua 5.4.9 process
outside the VM, started by a caller-held OTP Port from an executable that `build/2`
compiles from the installed pinned `lua_source` checkout and an owned C host, over
length-framed JSON, under capability policy version 2, whose fixed allow-list of names
and safe helper set (ten C helpers under the global `helpers`, each version 1, for JSON
null and empty object, canonical JSON encode and decode, ASCII trim, plain split, UTF-8
code-point count and UTC time values that the caller passes in) has a canonical identity,
with exact positive limits on counted steps, call depth, value bytes, live Lua memory and
wall time. Helpers charge counted steps for their work and their limits are the same
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
identity (a `policy-v1:` identity is refused as `policy_mismatch`); a mismatch is refused
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

## Policy version 2

Fresh library, `helpers` and environment tables; strict lookup of a missing global,
library field, helper or string method is `unlisted_name`. No bindings or callbacks.
Granted names (the helpers are in the next section):

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

The **identity** is `policy-v2:sha256:<64 lowercase hex>` over the canonical JSON of the
descriptor (sorted keys, sorted qualified names, wrapper versions, numeric and iteration
rules, fixed maxima, framing version, the ten sorted helper descriptors
`{"name", "version": 1}` and empty bindings). An unknown identity, including a
`policy-v1:` one, fails closed as `policy_mismatch`. The runtime identity
(release, revision, host SHA-256, build options, seed) is returned beside it; a changed
policy or build identity is not replay-compatible.

## Policy version 2: helpers

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
7. **`policy_v2_identity`** (`lua_sandbox_helpers_test.exs`): the descriptor names version
   2 and the ten helpers, the identity has the prefix `policy-v2:sha256:` and equals the
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

## Limits

* Not OS security isolation (above). No caller bindings, callbacks, pooling, in-VM execution.
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
