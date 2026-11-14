# ELZ-163 — Bounded outside-VM Lua sandbox

## Scope and reuse

- Dependencies: ELZ-033, ELZ-159, ELZ-160, ELZ-165
- Output: `runtime/lua-sandbox`; release V1B; RC-60 sandbox portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/lua-sandbox/**` and its index/generated changes under AGENTS.md section 3.

Owner decision (option A), 2026-11-14: ship policy version 1 with no helpers.
Every helper name refuses as `unlisted_name`. The separate
`runtime/lua-stdlib` Piece adds the safe JSON/text/time helper set as the next
policy version. RC-62 and RC-66 depend on lua-stdlib, so recipes never use the
helper-free version. The interface, policy names and bounds below are admitted;
finite implementation evidence is still required, not a security proof.

Owner runtime decision, 2026-11-14: PUC Lua 5.4.9 outside the VM over an OTP
Port with a small C host, built from the installed `lua_source` dependency.
Reuse ELZ-160's exact source identity and explicit library compilation recipe,
not its test-only executable or root test support. Install libraries, never
copy upstream Lua source into the Piece. No new provider, dependency or pin.

The manifest declares `kind: adapter`, providers `elixir`, `otp`, `lua_source`
and `jason`, and no Piece dependencies. Declare every owned C/header, Elixir,
test and example file in `files`. Native source belongs under
`lib/elzoo/lua_sandbox/native/`, not unsupported `c_src/`. Use uniquely named
test files. No fixture directory: adversarial sources are small test literals.

ELZ-165 preserves `compile: false, app: false` in install instructions and
makes selected source-only providers available through the copied consumer's
`Mix.Project.deps_paths()` using temporary path dependencies with the same
options and no application startup. Tests compile this Piece's own C under
`lib/elzoo/lua_sandbox/native/` against that `lua_source` checkout with plain
`cc`/`ar`. Compile fresh without catalogue-root lookup, cached executables,
network fetching inside Piece tests or skipped tests. No shared harness repair
or native build-hook change belongs to this task.

## Interface: `Elzoo.LuaSandbox`

`build(source_directory, build_directory)` returns `{:ok, executable}` or
`{:error, :build_failed}`. These are trusted host-supplied filesystem operands,
never Lua inputs. Use plain `cc`/`ar`, explicit pinned library source list and
owned C host, no shell expansion or build helper. Fail, never skip, on missing
tools. Build outside the source bundle; never ship generated binaries. The
consumer owns production build/install; build is not invoked per evaluation.

`policy()` returns `%{identity: identity, descriptor: descriptor}`. The descriptor
is immutable public plain data. `run(executable, request)` returns
`{:ok, %{value: value, identity: identity, runtime: runtime_identity}}`,
`{:refused, reason}`, or `{:host_outcome, reason}`. One fresh process and Lua
state per call, one request/reply, no shared state or environment inheritance
grant. A caller-held Port owner guarantees deadline, EOF and process cleanup;
caller death closes the child input and the child exits. No pooling or service.

Request has exactly `source`, `input`, `policy`, `limits`. Source is UTF-8 Lua
text at most 65,536 bytes, a chunk returning exactly one function accepting
one plain input and returning exactly one plain result. Empty source and zero
or multiple results are `invalid_result`. Never accept bytecode. Policy must
equal the built-in identity; reject a mismatch before executing any source.
Limits are exactly positive integers with these inclusive maxima: `steps`
1,000,000 counted VM instructions across chunk and function; `call_depth` 64
active Lua calls (tail calls do not accumulate depth); `value_bytes` 65,536
per string and per encoded input/result; `memory_bytes` 16,777,216 live Lua
allocator bytes including the baseline; `wall_ms` 1,000. No defaults or extra
keys. A budget below initialization needs refuses without running user code.
Count ordinary recursion and C-to-Lua callbacks; cap host traversal at 32
containers. Count bounds include the chunk's work, not only the returned call.

Plain input/result is null, booleans, UTF-8 strings, signed 64-bit integers,
finite binary64 numbers, dense ordered arrays or string-keyed maps. Specify a
distinct null/array/object representation, including empty array versus empty
object, without exposing mutable host objects or granting metatable access.
Reject holes, cycles, mixed/nonstring object keys, functions, userdata, threads
and nonfinite results. Enforce bounds before recursive traversal/encoding.

Protocol is an explicit unsigned 32-bit little-endian byte length followed by
UTF-8 JSON; both directions have a 1,048,576-byte payload maximum. Reject a
zero/overbound length before allocating the body. OTP `{packet, 4}` is not
this framing. Partial header/body, EOF, invalid JSON, duplicate object keys,
trailing bytes and multiple replies fail closed as `protocol_error`. Include
source/input JSON escaping overhead in the frame check. No source or input on
argv, diagnostics or stderr; process stdout is only the protocol.

Refusal reasons are fixed atoms `invalid_request`, `policy_mismatch`,
`invalid_result`, `steps`, `call_depth`, `value_size`, `unlisted_name`,
`lua_error`; host outcomes are `memory`, `wall_time`, `process_exit`,
`protocol_error`. Public errors contain no provider prose, stack, source,
input, executable name or filesystem operand. Memory is conservatively always
a host outcome because GC affects live-allocation timing; record it as input,
never recompute it as a deterministic replay decision. The same applies to
wall time and abnormal host exit. Limits are operands, not ambient Config.

## Policy version 1

Admission owns the base policy; the caller cannot replace it or add names.
Use ELZ-159's narrowed names, not the broad probe environment:

- `string.byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper`.
- `table.concat insert move pack remove sort unpack`.
- `math.abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger modf pi rad sin sqrt tan tointeger type ult`.
- Globals `ipairs select type tostring tonumber error assert pcall`.

Each library name above is qualified by its library. Constants are declared
as constants, not functions. Unnamed iterators are covered only by their
listed parent. No pairs/next, coroutine, xpcall, loaders, package, OS/I/O,
debug, GC, raw/metatable functions, print, dump or random access. Create fresh
library/environment tables; never filter an already shared global table.
Strict missing-global and library-field lookup yields `unlisted_name`,
including attempted method lookup through a shared string metatable. Ordinary
missing fields in user data remain data nil, not capability lookup.

`tostring` accepts only scalar text, finite numbers, booleans and nil; never
heap identity. `string.format` rejects `%p` and non-scalar `%s`, and accepts no
identity-bearing value via any conversion. Lock numeric locale to C, signed
64-bit integer wrap and binary64 semantics, deterministic hash seed, numeric
formatting and build options. Dense-array operations and their wrappers reject
sparse/mixed tables rather than promising portable sparse length semantics.
General Lua operators retain pinned-runtime semantics; no cross-build replay
claim. Test sparse length and numeric boundaries across fresh processes;
stop admission if a policy-only source produces differing results rather than
merely documenting nondeterminism. Unordered map traversal is not a capability.

Identity is `policy-v1:sha256:<64 lowercase hex>` over canonical UTF-8 JSON:
recursively sorted object keys, sorted fully qualified names and explicit
wrapper versions, numeric/iteration rules, fixed maximum bounds, framing
version and helper/binding descriptors. Use integers/strings in the descriptor
to avoid ambiguous floating encoding. Version 1 has empty helper and binding
descriptors and refuses additions; no callback API is introduced. RC-62 must
separately admit binding identity, schemas and replay classification before
adding functions under `bindings.<name>`; changed semantics changes identity.
Keep runtime version, upstream revision, C-host source SHA-256, numeric/build
options and seed identity alongside policy identity. Unknown identities fail
closed, including any future helper-enabled identity.

The owner-approved helper-free version 1 is the staged exception to RC-60's
helper requirement. `runtime/lua-stdlib` owns safe JSON/text/time helpers and
their identity/version tests in the next policy version; no placeholder helper
names are granted here. Neither clocks nor `helper_echo` are production grants.
Recipe tasks RC-62 and RC-66 require lua-stdlib, not this helper-free policy.

## Acceptance groups

1. **native_build_and_copy** — Compile installed pinned sources into a fresh
   static library and owned executable, execute 42 from a pure function in
   catalogue and isolated copied-consumer tests. Missing compiler, wrong source
   revision and failed build refuse. Remove the output directory after tests.
   Assert copied C bytes/receipt and no dependency on root support or prebuilt
   host. The changed-Piece consumer must finish within its existing 300 seconds.
2. **counted_sticky_limits** — Infinite loop reaches `steps`, ordinary recursion
   reaches `call_depth`, string.rep/concatenation/string.pack bombs reach
   `value_size` or the earlier named memory host stop. Test small budgets at the
   boundary and boundary+1 with known counted sources; test initialization and
   parser/allocation failures. A hook alone does not bound a single allocating
   C operation: guard allocation/string construction at the pinned Lua boundary
   as ELZ-159 requires, including its private-layout coupling. No fork or
   upstream source change is authorized; stop if one is necessary.
3. **no_catching_or_continuation** — For each stop exercise nested sticky C
   pcall, errors inside its handler path and repeated attempted catches; no
   post-stop marker, successful reply or host callback can occur. xpcall,
   coroutine.resume and coroutine.wrap are unreachable on all lookup paths.
   Host-side blocked-child testing forces the wall deadline independently of
   instruction count; wall and memory stops remain host outcomes. A temporary
   negative control disabling sticky rethrow must expose continuation; restore
   it before the final gate. Sticky state is outside Lua and cannot be reset.
4. **exact_capability_surface** — Compare exact names/constants from sandbox
   enumeration, C-host environment/shared-metatable audit and fixed-name/value
   probes. Exercise load/require, os/io/debug, _G/_ENV, string methods,
   returned iterators, shared metatables, raw access and every excluded catcher.
   Direct and indirect use refuse as `unlisted_name`, never nil-call prose or
   accidental access to upstream functions. Negative control granting print
   must fail the audit. No diagnostic audit entry point is available to Lua.
   Probe attempted JSON/text/time helper names and `helper_echo`: each ends
   in `unlisted_name`, with no placeholder callback or ambient clock access.
   Include the ELZ-159 reviewer's heap-address narrowing test: `tostring({})`
   and `tostring(function() end)` refuse as `lua_error`, never return table or
   function addresses; scalar tostring remains deterministic. Reject `%p`
   and identity-bearing `%s` through string.format too. Host-side probes cover
   thread/userdata inputs without exposing constructors or an audit API to Lua.
5. **plain_data_and_protocol** — Round-trip all scalar types, empty array/map,
   nested containers at depth 32 and refuse 33; byte limits at cap and cap+1;
   cycle/function/thread/userdata/nonfinite/sparse/mixed results refuse. Cover
   every malformed frame above, oversize output, child crash and stderr text
   containing a synthetic private marker. Returned errors/logs contain none
   of that marker or source/input. No log or telemetry leaks evaluation data.
6. **replay_and_survival** — Repeat pure arithmetic/string/array/map cases in
   20 fresh calls and two fresh BEAM processes with identical build/policy:
   equal value or deterministic refusal, including counted steps/depth/size.
   Include overflow, division/nonfinite, numeric formatting, patterns, sparse
   length and identity formatting attempts. Memory/time stops are recorded
   separately, not compared as deterministic results. Changed policy/build
   identity is not replay-compatible. After every adverse case the owning
   BEAM is alive, the child is reaped and a subsequent valid call succeeds;
   caller death also leaves no live child. Test cleanup, not only Port closure.

Evidence is finite real-process/compiler tests, upstream Lua/OTP contracts and
explicit assumptions about OS termination, pinned numeric/build semantics and
tool availability; no universal security proof or monitor claim. README and
piece.json name each group and the private-layout maintenance limitation.
Declare runtime executable/process/monotonic-timer Needs, no ambient authority,
and operations: no observation payload, no hot Config, no independent Control
API. Run `mix test pieces/runtime/lua-sandbox/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.

## Not in scope

Add no extra features. No stdlib helpers, caller bindings, recipe engine,
in-VM execution, pooling, package/store/secret access, new provider pin,
vendored upstream sources, CI/registry schema/export/harness edits, new build
helper, container/seccomp or claim of OS security isolation. Port separation
does not protect against a native-runtime vulnerability. ELZ-165 supplies the
merged prerequisite; this task does not waive the copied-consumer gate.
