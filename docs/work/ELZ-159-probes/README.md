# ELZ-159 runtime-fit probes

These are research sources, not executable inputs of the catalogue. Build and
run only after copying them outside the checkout. No dependency or toolchain
pin in the catalogue changes. All three candidate probes are recorded below.
No provider is selected or adopted by these probes.

## Shared cases and policy

`cases/*.lua` are the shared inputs; `cases/README.md` groups them. Each input
is evaluated with no input arguments, in a fresh runtime state. Policy v1 draft:

* `string`: byte char find format gmatch gsub len lower match pack packsize rep
  reverse sub unpack upper (not dump).
* `table`: concat insert move pack remove sort unpack.
* `math`: abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger
  min mininteger modf pi rad sin sqrt tan tointeger type ult (not random/randomseed).
* Globals: pairs ipairs next select type tostring tonumber error assert;
  optional host `pcall`; caller-given `helper_echo` (identity stub, not the
  final JSON/text/time helper set or a binding-identity design).
* No coroutine, xpcall, getmetatable/setmetatable, rawget/rawset/rawequal, loader,
  I/O, debug, process, clock or random capability. `_ENV` is Lua syntax for the
  fresh environment, not an extra global. `_G` is absent.

Every library table and the environment are built fresh from literal name lists,
not by deleting names. The host privately opens upstream libraries solely as
the source of those functions. A fresh string metatable has only `__index`
pointing to the listed string table; even upstream arithmetic metamethods are
not retained. Ordinary string/table field misses yield nil; unknown globals
raise exactly `unlisted name: <name>` (also tested with nil behavior). Writes to
the fresh environment/tables are not forbidden; they cannot reveal private
globals, but this is not a frozen-policy implementation.

Bounds shared by subsequent candidates: 1,000,000 steps, 16 MiB runtime live
allocations, call depth 200, string value 1 MiB and serialized result 1 MiB,
wall time 2 seconds. Drivers must report unavailable bounds rather than silently
claiming equivalent enforcement. JSON lines name candidate, case, outcome,
detail and steps (`null` when unknown); host cases also report continuation
sentinel reachability and the driver reports BEAM survival after each request.

## Candidate 3: PUC Lua 5.4.9 in an OS process

Upstream source: https://www.lua.org/ftp/lua-5.4.9.tar.gz

SHA-256: `2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6`

Latest 5.4.x and checksum read from https://lua.org/ftp/ on 2026-11-13.
License: MIT, included in the release's `doc/readme.html`.
Build: stock release `liblua.a`, Linux C compiler, make, ar, libm and libdl;
small C host links statically to Lua. No fork or patched upstream source.
Requires Linux `prlimit`, curl, tar, sha256sum, Git and Elixir/OTP with the
built-in OTP `:json` module (run here with Elixir 1.20.4 / OTP 29).

From the checkout root, with a fresh scratch destination:

```sh
mkdir -p "$HOME/scratch/elz159"
cp -R docs/work/ELZ-159-probes "$HOME/scratch/elz159/probes"
cd "$HOME/scratch/elz159/probes"
sh puc/build.sh
elixir puc/driver.exs > run1.jsonl
elixir puc/driver.exs > run2.jsonl
```

The build script refuses to build inside any Git worktree. In this probe host,
lua.org HTTPS downloads failed with `curl: (35)` (TLS EOF/reset), while GitHub
and the toolchain worked. The upstream index was readable through the web tool.
The actual release archive was obtained from the NetBSD cache, and its bytes
matched the upstream checksum above:

```sh
LUA_URL=https://cdn.netbsd.org/pub/pkgsrc/distfiles/lua-5.4.9.tar.gz sh puc/build.sh
```

An existing archive is always checksum-checked. Nothing downloaded or generated
belongs in the checkout. Output paths above are scratch paths, not deliverables.

### What the host actually enforces

* Wire: unsigned 32-bit big-endian source byte length, then source bytes on
  stdin; initial readiness line, then one JSON line per request on stdout. Multiple requests per process are allowed,
  but each creates/closes a fresh Lua state. Only text chunks, fixed `=probe`
  source label. Input length <=1 MiB. The framing implementation targets this
  Linux little-endian host, not a portable production protocol.
* Step hook: count granularity **one VM instruction**, no sampling. Counts
  source instructions, not parsing, C library work, serialization or elapsed
  time. Call hooks reject a visible Lua stack depth above 200 (C frames count;
  tail calls do not increase the visible stack). Same-source stop counts are
  compared in fresh OS processes; they are version/build-specific, not portable
  instruction counts.
* Allocator: counts bytes of each live Lua allocation, including library setup,
  parser and runtime. Refuses growth above 16 MiB and keeps a sticky stop flag,
  even if Lua's GC retry would subsequently succeed. This is a hard live-byte
  cap, **not** a deterministic cumulative allocation budget: GC timing and
  allocator/runtime changes can affect the stop. Treat memory refusals as host
  outcomes for replay despite observed repeated counts.
* String cap: new allocations tagged LUA_TSTRING cannot exceed 1 MiB of string
  payload. Uses the pinned release's private TString layout (`offsetof` plus
  trailing NUL), not a stable public API. Runtime strings created through
  concatenation and C libraries are covered; transient luaL_Buffer storage is
  governed by total memory before the final string is made. Table size is not
  bounded by this string cap. The separate plain-result serializer caps total
  encoded bytes at 1 MiB and rejects functions, threads, userdata, unsupported
  keys/values, nonfinite numbers and depth >200 (including cycles).
* Plain tables are encoded as sorted lists of key/value pairs, not JSON objects,
  preserving mixed key types. The host canonicalizes **representation**, not
  Lua iteration order. Strings are byte-oriented (`\\u00xx` escapes for non-ASCII
  bytes); this is not a production Unicode/JSON schema decision.
* Limit flag is sticky; a C pcall replacement rethrows it. The hook re-errors
  every instruction after a stop. Catch cases call `helper_echo('continued')`
  after the catch; the C host separately records whether that sentinel ran,
  rather than merely hiding a continued result behind its stop flag. Ordinary
  errors remain catchable. xpcall and both coroutine catching interfaces are
  unreachable under policy.
* Coroutine diagnostic mode deliberately grants the upstream coroutine table,
  solely to observe hook inheritance. This mode is **not** the policy. A child
  thread inherits the hook and budget pointer; count-hook stop must occur
  without falling back to the wall timer. The main thread's next instruction
  can add one to the shared count after coroutine.resume returns the error.
* Wall diagnostic mode deliberately blocks the helper for 10 seconds and
  disables the instruction hook, to exercise the 2-second Port timer. The
  driver kills the Port's OS pid with SIGKILL and closes the Port; the executable
  is invoked through prlimit (exec, not a shell process tree). All processes
  have a 256 MiB address-space ceiling, including host-side serialization.
  No network/filesystem namespace or syscall isolation is claimed.
* Host-visible ordinary errors are reduced to `runtime error`; unlisted errors
  retain only the fixed name message. The error-text determinism case catches
  errors *inside Lua* and exposes the fixed chunk label, not host file paths.
  Intentional user text is not a reliable secrecy boundary. No pid/hostname/path
  is supplied as Lua input. These finite probes are not a proof of isolation.

### Reading the output

`host_allowlist_audit` inspects environment, its metatable and the full shared
string metatable through the C API. Ordinary new tables and functions have no
shared metatable. `enumeration` walks from inside; `fixed_names` tests globals
and string method lookups. Compare those surfaces, not just the globals table.

The broad `determinism` case intentionally includes unsafe-for-replay pointer
`tostring` and unspecified traversal order. Its fresh-process comparison may
be false: that is a finding, not a harness failure. `determinism_pure` should
compare equal. Each primary limit case also runs twice in fresh processes.
The driver prints full comparisons, allowing comparison again after a BEAM
restart (the second driver command). Narrowing traversal to ordered input and
forbidding tostring of identity-bearing values are admission questions.

Cost numbers are microseconds: 200 timed requests to an already-open process,
each with fresh state, including parsing, execution, plain serialization and
Port/JSON overhead. Also reports each workload's first request in a new process
and cold open+evaluate+close cost. OS start cost is open-to-readiness plus Port
close (200 runs), including prlimit exec and C host startup, before any Lua state
exists. Recipe cost includes encoding
the full 200-entry table. CPU count and memory size are the only host identity.
The earlier candidate-3 report's "4 CPUs" measured
`System.schedulers_online()`, not host processors. On this host, `nproc` and
`:erlang.system_info(:logical_processors)` / `:logical_processors_available`
report **8**; `System.schedulers_online()` and `:schedulers_available` report
**4**. The environment sets `ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`.
Thus the BEAM is configured with four online/available schedulers on eight
reported logical processors. Memory is `MemTotal: 32866572 kB`. Candidate 3's
measurements used that four-scheduler BEAM configuration too.

### Optional fixed-seed build experiment

Observed (`puc/seed_probe.py`, 50 fresh OS processes per executable): the
default build produced 50 distinct pairs orders and 50 next orders; the
fixed-seed build produced one of each. Table tostring identities still had
50 distinct values in both builds. This is not a traversal guarantee for
other keys, insertion histories or releases, and fixed hashing can weaken
collision resistance. Retain the proposed ordered-traversal narrowing.

Read upstream (2026-11-14):
https://www.lua.org/source/5.4/lstate.c.html and the pinned 5.4.9 tarball's
`src/lstate.c` guard the seed function with `#if !defined(luai_makeseed)`.
Its exact override is the function-like macro `luai_makeseed(L)=0`, not
`LUAI_HASHLIMIT`. The default function hashes time plus addresses of the
state, a local variable and lua_newstate (heap/stack/function addresses,
explicitly intended to benefit from ASLR). Overriding it removes those seed
inputs, but does not remove pointer identity elsewhere. This is an optional
compile-time build option, not a source fork.

In the prepared scratch `puc/` directory, preserving the default `host`:

```sh
LUA_FIXED_SEED=1 sh build.sh
python3 seed_probe.py
```

The variant produces `host-fixed-seed`. The build always cleans the extracted
Lua objects so a flag change cannot reuse the other build's library. Run
`sh build.sh` first in a new directory to produce the default host as well.

## Candidate 1: Hex `lua` 1.0.2, in the BEAM

### Provenance and rerun

Read 2026-11-14:

* https://hex.pm/api/packages/lua/releases/1.0.2 gives outer package SHA-256
  `cf14ab77c27f1acf2fb933b82530bd728dab8a69e7a05757e21a3b49180d4690`.
  `mix hex.package fetch lua 1.0.2` plus `sha256sum lua-1.0.2.tar` matched it.
* https://hex.pm/api/packages/lua lists `Apache-2.0`; the shipped `LICENSE`
  begins `Apache License, Version 2.0, January 2004`. These agree.
* Release `requirements` is `{}`. Shipped `mix.exs` and `lib/lua/vm/**` show a
  standalone Elixir parser/compiler/VM, not a luerl wrapper. Its luerl dependency
  is `only: :benchmark`; other dependencies are development/test tooling.
  The probe lock contains only `lua`.
* The package source/README targets Lua 5.3; observed `_VERSION` is `Lua 5.3`.
  This is not a claim of complete PUC compatibility. Coroutine is not installed.
  Observed examples include 64-bit integer wrap, integer division, numeric
  formatting, holes and pattern behavior in the unchanged shared cases.

Use the scratch copy described above (or copy into a fresh destination), then:

```sh
cd "$HOME/scratch/elz159/probes/lua_ex"
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted mix.exs probe.exs
mix hex.package fetch lua 1.0.2
sha256sum lua-1.0.2.tar
mix run probe.exs > lua-run1.jsonl
mix run probe.exs > lua-run2.jsonl
python3 check.py lua-run1.jsonl lua-run2.jsonl
```

Run only in scratch. Keep `mix.exs`, `mix.lock`, `probe.exs`, `check.py` as source;
never copy `deps/`, `_build/`, tarballs or JSON outputs back into the checkout.
Observed build: Elixir 1.20.4 / OTP 29; 63 package source files compiled, no
package warnings or failures. An initial probe-script type warning was fixed
before the final two runs. Both final fresh `mix run` invocations exited 0 with
106 JSON lines each. `check.py` checks the shared cases, host survival, audits,
plain values, normal/empty/error boundaries and observed limitations; it is
deliberately not an assertion that this candidate meets RC-60.

Negative control: temporarily added `print` to the scratch copy's policy
globals, reran the driver, and ran the same checker. It failed as intended
with `AssertionError: unexpected policy global`. Restored the scratch source
from the deliverable and checked byte equality. Diagnostic pcall/xpcall cases
also serve as counterexamples to any claim that their runtime stops are
uncatchable; their successful continuation is retained as evidence, not hidden
by the checker.

### Eight-section findings (observed unless marked read)

1. **Limits.** The public `Lua.new/1` options are used with
   `max_instructions: 1_000_000`, `max_call_depth: 200`,
   `max_string_bytes: 1_048_576`. The fresh state copies these configured fields.
   Infinite loop, recursion and string doubling respectively stop as
   `steps_exceeded` (count 1,000,000), `depth_exceeded`,
   `value_size_exceeded`. Read from `Lua.VM.State.tick!/2` and public option
   docs: instructions count loop back-edges/call boundaries, **not each Lua
   opcode**; no equivalence to PUC instruction counts is claimed. Error counts
   other than the stamped instruction-budget stop are unknown (`null`).

   **The string bound is incomplete:** extra diagnostics using policy-allowed
   `table.concat`, `string.gsub`, `string.format` and `string.pack` each build
   2,097,152 bytes with a 1,048,576-byte setting, then return the length. A
   post-evaluation result check cannot prevent those intermediate allocations.
   Only modest 2 MiB examples were run; no node-exhaustion attempt was made.
   These agree with the separately read upstream issue
   https://github.com/deviceio/lua/issues/425 (open on 2026-11-14).

   No runtime memory option exists. The host evaluates in a fresh unlinked,
   supervised Task, setting `max_heap_size` to 16 MiB / wordsize,
   `include_shared_binaries: true`, `kill: true`. Large table allocation kills
   that worker and produces host `memory_exceeded`; the BEAM survives.
   **This is a GC-time backstop, not a hard allocation ceiling or deterministic
   memory budget.** Large individual binaries may allocate before a GC check;
   BEAM-process isolation is not OS-process failure isolation. Wall enforcement
   is `Task.yield(task, 2000)` then `Task.shutdown(task, :brutal_kill)`.
   A deliberately blocking helper, also inside `pcall`, times out at the host.

2. **Uncatchable stops.** Production-policy runs exclude `pcall`, since the
   conditional policy requirement is not met. Diagnostic fresh environments
   add only `pcall`, or `pcall` plus `xpcall`. All three runtime limits are
   caught by both; every shared catch case reaches `helper_echo('continued')`
   and returns `ok` with `continued:true`. Literal-return diagnostics additionally
   return the caught error and `false`. Host memory kills and Task timeouts
   are not caught. `coroutine.resume`/`wrap` cannot be tested as catchers:
   coroutine is absent even in the package's default environment (fixed-name
   and host inspection), not just removed by our policy. Read `Lua.new/1`
   option validation and `lua_pcall`/`lua_xpcall`: no public sticky/uncatchable
   limit option exists in 1.0.2. No custom replacement was added to mask that.

3. **Escape paths.** The unchanged escape cases refuse loaders, I/O, OS, debug,
   raw operations, metatable access and `_G`. `_ENV` is the fresh table;
   `string.dump` and `('x').dump` yield nil. Inside-source enumeration reports
   only policy names; the host audit independently walks the global table,
   its metatable and all shared type metatables. Only a string metatable with
   a restricted `__index` table is installed. Fixed-name probes and string
   methods agree. `fixed_names` needs pcall, so its complete diagnostic run is
   explicitly suffixed `:with_pcall`; its ordinary policy run refuses pcall.
   These finite probes are not a proof against all VM escapes.

4. **Allow-list fit.** `Lua.new`/`Lua.sandbox` offer a deny-list, replacing
   blocked functions with erroring stubs, not removing names. The default
   environment still enumerates debug, raw/metatable functions, random and
   OS library entries; fixed probes see loader names as functions, but the
   actual default `load` call errors `load(_) is sandboxed` (not a working
   loader escape). Default inspection/enumeration outputs are diagnostic only.
   A truly fresh policy was constructed here using **internal**, public-callable
   `Lua.VM.State.new/0`, table allocation/global setters and native-function
   values copied from upstream. No global table or shared metatable was reused;
   no deletion-based filtering was used. Public `Lua.eval!` executes this state.
   This is version-pinned internal-API coupling, not a supported public
   environment-builder API. The full host-side source state is never supplied
   to the untrusted VM. A private native `__index` raises the fixed name error;
   the nil-lookup alternative is also exercised. No environment freezing is
   claimed. The helper is an identity callback; the real helper binding design
   remains untested.

5. **Determinism.** Two fresh BEAM invocations agree for pure computation and
   each limit outcome. Broad `determinism:with_pcall` differs at function
   `tostring` identity; the ordered pairs/next strings, table display ID,
   numeric results, holes, error strings and patterns happened to match these
   two runs. That is not a general ordering guarantee. Function identity also
   differs across fresh evaluations within one BEAM. Shared cases are unchanged;
   the diagnostic pcall suffix discloses the otherwise forbidden capability.

6. **Plain data/errors.** Host validation returns only the first result,
   representing Lua tables as sorted arrays of key/value pairs (not JSON
   object coercion). Empty/nested data succeed; returned functions/nested
   functions and cycles are refused. Threads are unavailable. Exact string
   construction boundary succeeds; one byte over via `string.rep` refuses.
   The large result case hits the host heap backstop before output size checks;
   no guarantee that all oversized outputs get `value_size_exceeded` is made.
   Serialized results are checked at 1 MiB, after construction. Errors use a
   fixed source label `probe`, omit stack traces, and sanitize paths, host
   identity and process displays. Observed fixed error is
   `Lua runtime error: fixed failure (at probe:1)`. This probe's refusal mapping
   uses message text; Lua can forge such error text, so it is **not** a trusted
   production stop-classification API.

7. **Cost.** Two fresh-BEAM runs, microseconds:

   | Workload | Run 1 median / p95 | Run 2 median / p95 | First workload request, run 1 |
   | --- | ---: | ---: | ---: |
   | 200-entry recipe | 974 / 1,103 | 985 / 1,126 | 1,117 |
   | Sum/format 1,000 numbers | 162 / 195 | 161 / 194 | 245 |

   Each is 200 requests, a fresh Task/state each time, including environment
   construction, parse/compile/evaluation, plain-data validation and JSON size
   encoding, but excluding printing the JSON line. The first cold-in-BEAM
   `return 42` request was 35,953 us (second BEAM: 39,431 us), including lazy
   module/bootstrap initialization. Mix/BEAM OS startup is excluded, unlike
   the separately measured PUC process startup. This is an end-to-end probe
   cost comparison, not isolated VM speed or an allocation benchmark. No
   long-running-state accumulation/stress benchmark was performed.

8. **Build/maintenance (read 2026-11-14).** Hex metadata links to
   https://github.com/tv-labs/lua, which currently redirects to
   https://github.com/deviceio/lua. Release API
   https://api.github.com/repos/deviceio/lua/releases lists v1.0.2 published
   2026-07-29, v1.0.1 on 2026-07-16 and v1.0.0 on 2026-07-15. Hex release
   metadata records insertion 2026-07-29. Repository API
   https://api.github.com/repos/deviceio/lua reports not archived, last push
   2026-10-22. Both Hex package/release `security_advisories` and
   https://api.github.com/repos/deviceio/lua/security-advisories returned `[]`.
   This means **no published advisories returned by those APIs**, not no known
   defects or a security certification. Open issues include #425 (string cap),
   https://github.com/deviceio/lua/issues/411 (instruction accounting) and
   https://github.com/deviceio/lua/issues/429 (long-lived table retention).
   Only #425's four policy-reachable string paths were independently probed
   here; the other issue reports are read claims, not observed failures.

Candidate-1 fit blockers at these settings are the incomplete string cap,
GC-time-only memory backstop, catchable runtime limits when protected calls are
admitted, identity-bearing tostring and internal-API-only fresh policy setup.
This is a provider-fit input, not a final recommendation or runtime selection.

## Candidate 2: luerl 1.5.1

Two guarded runs each emitted **123 JSON records**, including all 60 unchanged
shared cases. This is a provider-fit input, not a runtime selection.

### Rerun outside the checkout

From the repository root, with Elixir 1.20.4 / OTP 29, Python 3 and Linux
`/proc` available. Allow several minutes per run.

```sh
work="$HOME/scratch/elz159/luerl-rerun"
mkdir -p "$work"
cp -R docs/work/ELZ-159-probes/luerl "$work/"
cp -R docs/work/ELZ-159-probes/cases "$work/"
cd "$work/luerl"
mix deps.get
mix compile
mix hex.package fetch luerl 1.5.1
sha256sum luerl-1.5.1.tar
mix format --check-formatted mix.exs probe.exs
python3 run.py > "$work/run1.jsonl"
python3 run.py > "$work/run2.jsonl"
python3 check.py "$work/run1.jsonl" "$work/run2.jsonl"
```

**Use `run.py`, not unguarded `mix run probe.exs`.** The runner refuses
checkout execution. Each ordinary case gets a fresh BEAM; both cost loops
share a separate fresh BEAM per run. Every invocation has an outer 512 MiB RSS
watchdog sampled every 5 ms and a 15-second deadline (120 seconds for costs).
A killed BEAM records `beam_survived:false`; the Python harness surviving is
not successful worker isolation. RSS sampling can overshoot; it is not a hard
allocation ceiling. Per-case isolation is probe safety, not an outside-BEAM
runtime implementation.

Inside the BEAM, a Task/controller and linked sandbox runner each receive a
16 MiB-target `max_heap_size` map with `kill:true` and normally
`include_shared_binaries:true`. The Task deadline is 2 seconds. The binary
comparison sets that flag false for `limit_value:default_binary_accounting`
and true for `limit_value:shared_binary_accounting`; both run the unchanged
shared doubling-string source. Diagnostic suffixes identify policy departures.

Earlier whole-suite attempts included exit 137 and a 512 MiB RSS guard stop,
even with shared-binary accounting enabled. The exact allocating process/cause
was not established: kernel logs were unavailable and OOM counters were not
sampled beforehand. These are not completed comparison runs. Successful final
per-case results do not establish a hard memory guarantee or erase those
earlier observations.

### Provenance

Exact Mix pin: `{:luerl, "== 1.5.1"}`. Hex release metadata at
https://hex.pm/api/packages/luerl/releases/1.5.1 and the fetched tarball agree
on outer SHA-256:

```text
abf88d849baa0d5dca93b245a8688d4de2ee3d588159bb2faf51e15946509390
```

Hex metadata says Apache-2.0; shipped `LICENSE` contains Apache License 2.0.
This is an Erlang Lua implementation, not a wrapper; Hex runtime requirements
are empty. Observed `_VERSION` is `Lua 5.3`, not compatibility certification.

### Findings against the eight issue sections

1. **Limits.** `src/luerl_sandbox.erl:do_run/3` spawns a runner;
   `wait_reductions/2` polls `process_info(Runner, reductions)` every 100 ms
   and uses `exit(Runner, kill)`. These are host BEAM reductions, not Lua
   instructions. For a 1,000,000 target, stop samples were:

   ```text
   run 1: 28725238,29585275,29401267,29697280
   run 2: 28753240,29373266,29281262,29149257
   ```

   A finite source completed successfully at sampled reductions 2,604,668 /
   2,604,687. Thus this is not even a precise reduction ceiling. No native
   step/depth/value budget was found in the inspected evaluator. Public
   call/line tracing emitted only `current_line` and `fcall` for the empty
   loop, not an event per iteration. **This does not meet RC-60's deterministic
   inside-runtime step-limit requirement.** JSON `steps` is always null;
   reduction samples are separately labelled host outcomes.

   Explicit-local recursion to depth 250 succeeded. Unbounded explicit-local
   recursion, bare or protected, hit the host heap backstop. The unchanged
   shared `local function f` case instead errors `undefined function nil`:
   an observed semantics difference, not a depth refusal. Shared recursive
   enumeration has the same issue; a supplementary explicit-local variant
   works without modifying the shared source.

   A 2 MiB string was constructed and passed to a helper. Returning it hit
   host JSON-result validation. There is no native 1 MiB value bound. Host
   result traversal also has a depth-200 check, not a Lua call-depth limit.

   Memory accounting matters. With `include_shared_binaries:false` (default
   off-heap binary accounting), the string bomb required **whole-BEAM RSS
   kills in both runs**, at sampled peaks 527,292 / 524,916 KiB. With the flag
   true, the worker heap backstop stopped it and the BEAM survived, at sampled
   whole-BEAM peaks 127,380 / 122,212 KiB. All other final cases survived.
   This remains GC-time enforcement, not a hard 16 MiB quota or a guarantee
   for arbitrary sources. The shared string source reaches
   `luerl_emul:concat_op/3`, which concatenates binaries without a Lua
   value-size check; that is not a confirmed explanation of the earlier
   whole-suite exit. The outer Task wall deadline is necessary because the
   package reductions-poll loop precedes its timeout receive.

2. **Uncatchable stops.** Protected loop/allocation/string and explicit-local
   recursion diagnostics did not reach the continuation helper after host
   stops. These are process kills, not sticky runtime errors. A blocking
   helper, including inside pcall, hit the Task wall deadline. A whole-BEAM
   RSS kill is not catchable and loses the evaluating BEAM. Ordinary Lua
   errors are catchable: shared recursive sugar continued after its nil
   function error. That is not a caught depth stop. `xpcall` and coroutine
   are absent in the inspected package surface and diagnostic probes;
   resume/wrap catchability is unavailable, not established safe. Policy
   omits protected calls; diagnostic pcall is not RC-60 admission.

3. **Escape paths.** Fresh-policy probes refuse loaders, OS/I/O/debug,
   metatable/raw operations and GC through fixed unlisted-name errors.
   Restricted string dump lookup is nil. Default `luerl_sandbox` is a
   deny-list: clock/date, random, print, debug, metatable/raw functions and
   string.dump remain. Several blocked loader/I/O names are string-valued
   `sandboxed` markers, not executable capabilities. Enumeration alone is
   not evidence of loader execution; finite probes are not an escape proof.

4. **Allow-list fit.** Public `_G` assignment via `luerl:set_table_keys`
   returned `type(io)=='table'` while `type(_G.io)=='nil'`: it does not
   replace actual global name resolution. The inspected public API has no
   actual-global-table setter. Fresh tables are constructed, then internal
   state/heap records replace the global table and string metatable. This is
   version-coupled, not a supported public environment-builder interface.

   Transformed inside enumeration, host global/shared-metatable inspection
   and fixed-name probes through values agree for the tested policy names
   in both runs. Fixed probes add diagnostic pcall to continue after refusals;
   that addition is checked. The fresh environment has an `_ENV` self-alias,
   not default `_G`. Global misses raise `unlisted name: <name>`; the
   alternate nil-global mode returns nil. Missing library methods stay nil.
   Five requested functions are absent: string.pack, string.packsize,
   string.unpack, table.move and math.ult.

5. **Determinism.** Pure computation and seven isolated traversal, identity,
   hole, numeric, overflow, pattern and error components agree across fresh
   BEAMs, excluding OS RSS telemetry. This is observed equality, not a general
   ordering/identity guarantee. The broad diagnostic consistently errors
   `bad arithmetic '//' on 3,0.0`: repeat equality is not numeric compatibility.

   Results include `next: 2,7,false,a,z` but `pairs: 2=3,7=4`: generic-for
   stopped at the false key, an apparent semantics gap. Tostring returned
   `table: 20` / `function: 0`; sparse-table length was 1. Numeric strings
   include `1.0e15`, `9.007199254740992e15`, `0.3333333333333333`,
   `1.5`, `3`. `math.maxinteger+1` returned 9223372036854775808 rather
   than signed-64 wraparound. Patterns returned `aXbX` and captured `12`;
   formatting one-third to 17 digits gave `0.33333333333333331`.

6. **Plain data/errors.** Empty/nested tables succeed; functions, nested
   functions and cycles are refused by host validation. Threads are unavailable.
   Non-plain Erlang representations fall through to refusal; not every such
   type was constructible and separately tested. Serialization uses sorted
   key/value arrays with a 1 MiB JSON-result bound, not a Lua value-size cap.
   `plain_error` returns `fixed failure`. Empty protected-call diagnostics
   report package `function_clause` errors, not successful empty-return
   semantics. Paths, hostnames and process identifiers are sanitized.
   Message-based refusal classification is spoofable, not a production API.

7. **Cost.** Microseconds; 200 timed requests per workload. Includes fresh
   Task/state/environment, parse, execution, validation and sandbox polling;
   excludes JSON-line printing and Mix/BEAM OS startup.

   | Workload | Run 1 median / p95 | Run 2 median / p95 | First workload request, run 1 |
   | --- | ---: | ---: | ---: |
   | 200-entry recipe | 101,002 / 101,159 | 100,997 / 101,198 | 101,302 |
   | Sum/format 1,000 numbers | 100,999 / 101,112 | 100,998 / 101,148 | 100,338 |

   Cold-in-BEAM first evaluation: 134,369 / 124,068 microseconds, including
   lazy initialization but excluding OS startup. The roughly 100 ms floor
   follows from the package monitor sleeping 100 ms even when the short-lived
   runner has already finished. These are limiter-enabled sandbox costs, not
   bare-interpreter timings. Host: 8 logical processors, 4 configured BEAM
   schedulers, 32,866,572 kB memory, as reconciled above.

8. **Build/maintenance.** Scratch build succeeded on Elixir 1.20.4 / OTP 29,
   with package warnings for deprecated catch syntax and exported variables
   in equality expressions, including luerl_lib_string, luerl_lib_basic,
   luerl_heap, luerl_scan and luerl_lib. No package source was modified.

   Read on 2026-11-14: Hex release metadata and
   https://api.github.com/repos/rvirding/luerl/security-advisories returned
   no published advisories; this is not a security certification. Release API
   https://api.github.com/repos/rvirding/luerl/releases listed v1.5.1 published
   2025-12-03, v1.4.1 on 2025-05-08 and v1.4.0 on 2025-05-06. Hex insertion
   was 2025-12-03. Repository API https://api.github.com/repos/rvirding/luerl
   reported not archived, last push 2026-10-24. An unauthenticated refresh
   hit a rate limit; authenticated gh api succeeded. These are read claims,
   not probe observations.

### Checker and negative control

The checker validates schema, all shared cases, normal/empty/error returns,
three-path audits, catchability, binary-accounting modes, reported guard kills,
fresh-BEAM components and cost counts. Passing it accepts observed provider
shortcomings, not RC-60 compliance.

Temporarily adding print to fresh policy globals made the audit fail with
`AssertionError: unexpected policy global`. The edit was restored and scratch
source compared with the deliverable. Public `_G` swap is a separate negative
environment-construction experiment. No runtime is selected.
