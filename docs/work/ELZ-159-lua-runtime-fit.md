# ELZ-159: provider-fit record for a bounded Lua runtime

## Scope and evidence

**Read repository Contract (2026-11-14):** [issue #347](https://github.com/balungpisah/elzoo/issues/347)
and the RC-60 row in [release-plan.json](../plans/release-plan.json) require
a provider-fit record before provider adoption or Piece admission. No runtime
is selected by this document; the recommendation and policy below are proposals.

**Observed (shared probe runs):** three candidates ran outside the checkout,
using the unchanged shared cases and nominal targets of 1,000,000 steps,
16 MiB memory, call depth 200, string/result size 1 MiB and 2 seconds wall time.
Unavailable limits are findings, not equivalent substitutes. The host reports
8 logical processors, 4 configured BEAM schedulers and 32,866,572 kB memory.

**Evidence convention:** paragraphs marked **Observed** name the probe/case;
**Read upstream** names a dated URL reference. Verdicts, recommendation and
admission answers are **proposals derived from those observations**, not
additional observed guarantees. JSON excerpts are selected-field projections
of emitted records, with identity-bearing values omitted where unnecessary.
Full rerun preparation, exact library-name lists, safeguards and negative
controls are in the [probe README](ELZ-159-probes/README.md). Commands below
run in those prepared scratch directories, never in the checkout.
The listed probes pass; finite scenarios are not a proof of isolation.

## Summary verdicts

| Candidate | Limits | Uncatchable stops | Escape paths | Allow-list fit | Determinism of a policy-only source | Plain data and errors | Cost | Build and maintenance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| lua 1.0.2, inside VM | does not fit: string-size bypasses and GC-time memory backstop | does not fit: pcall and xpcall catch runtime stops | fits with fresh environment and restricted string metatable | fits with version-coupled internal state construction | fits with replay-domain narrowing and runtime identity | fits with host plain-data validation and sanitization | fits with measured latency budget | fits with pinned toolchain |
| luerl 1.5.1, inside VM | does not fit: no runtime step budget and default binary-accounting BEAM loss | does not fit: no uncatchable runtime step limit exists | fits with fresh environment and restricted string metatable | does not fit: five draft-policy functions absent | fits with runtime-specific semantics and replay-domain narrowing | fits with host plain-data validation and sanitization | fits with 101 ms sandbox latency budget | fits with OTP 29 package warnings accepted |
| PUC Lua 5.4.9 over a Port | fits with maintained C host and recorded host outcomes | fits with sticky stops and C pcall replacement | fits with fresh environment and restricted string metatable | fits with C-host allow-list construction | fits with replay-domain narrowing and pinned build | fits with bounded C-host serialization | fits with measured Port latency budget | fits with GitHub-hosted toolchain validation before adoption |

## Recommendation

**Proposal:** recommend PUC Lua 5.4.9 **outside the VM through a Port**, using
the small C host. Observed count-hook stops provide deterministic in-runtime
step counting, and sticky stops plus the host pcall replacement prevent the
tested continuations. The counting allocator imposes a hard live-allocation
cap, but a memory stop affected by GC timing remains a host outcome; wall-time
and OS-limit outcomes must likewise be recorded as inputs and not recomputed
on replay. Conditions are maintained native C code, a string-size check tied
to the private TString layout of this pinned release, traversal/tostring and
numeric-domain narrowing, versioned caller bindings, and a successful build
and integration gate on GitHub-hosted runners before adoption. Neither in-VM
candidate meets the step-limit requirement uncatchably: lua catches its
runtime stops and has string-size bypasses; luerl polls host reductions and
its default binary-accounting string bomb loses the evaluating BEAM to the
RSS guard. This recommends a provider-adoption proposal, not an adoption or
an assertion of a complete security boundary.

## Candidate 1: Hex lua 1.0.2, inside the VM

### Observed draft-surface catalog used by the three-path sections

**Observed (lua enumeration/host_allowlist_audit/fixed_names:diagnostic;
PUC enumeration/host_allowlist_audit/fixed_names):** the common draft library
surface, called **S** below, is:

- string: byte char find format gmatch gsub len lower match pack packsize rep
  reverse sub unpack upper.
- table: concat insert move pack remove sort unpack.
- math: abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger
  min mininteger modf pi rad sin sqrt tan tointeger type ult.
- Scalar globals **G**: pairs ipairs next select type tostring tonumber error
  assert helper_echo; string/table/math are the library table names.

**Observed (the same three paths):** lua policy reaches S and G on every
path; diagnostic fixed probes additionally grant pcall. PUC policy reaches S
and G plus sticky C pcall on every path. String-method lookup reaches exactly
the listed string fields. Host inspection sees the fresh string-metatable
__index table and the environment's refusal __index function; absent
getmetatable/raw operations prevent treating those host implementation paths
as extra author capabilities. New ordinary tables/functions carry no granted
shared capability metatable.

**Observed (luerl enumeration:explicit_local/host_audit:policy/
fixed_names:diagnostic):** all three paths reach S minus string.pack,
string.packsize, string.unpack, table.move and math.ult, plus G. Inside/host
enumeration additionally sees the _ENV self-alias; fixed probes additionally
grant diagnostic pcall. The shared recursive enumeration errors rather than
enumerating; agreement uses only its explicitly labelled supplementary
variant. These are observed broad-draft names, not the narrowed policy below.

### 1. Limits

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (limit_steps, limit_depth, limit_memory, limit_value; value_bypass:*):** the configured loop/call-boundary budget, call-depth and string-doubling cases refuse; the evaluating Task heap backstop survives the large allocation. However table.concat, string.gsub, string.format and string.pack each build 2 MiB despite the 1 MiB option. Memory refusal is GC-time dependent, not a hard per-allocation quota. **Read upstream ([LuaGuide], 2026-11-14):** instruction accounting is at loop back-edges/call boundaries, not every opcode.

```jsonl
{"case":"limit_steps","outcome":"steps_exceeded","detail":"Lua runtime error: instruction budget exceeded","steps":1000000,"continued":false,"beam_survived":true}
{"case":"limit_depth","outcome":"depth_exceeded","detail":"Lua runtime error: stack overflow","steps":null,"continued":false,"beam_survived":true}
{"case":"limit_memory","outcome":"memory_exceeded","detail":"host max_heap_size GC-time kill (16 MiB target)","steps":null,"beam_survived":true}
{"case":"limit_value","outcome":"value_size_exceeded","detail":"Lua runtime error: resulting string too large","steps":null,"continued":false,"beam_survived":true}
{"case":"value_bypass:table_concat","outcome":"ok","detail":2097152,"steps":2047,"continued":false,"beam_survived":true}
```

Verdict: **does not fit: string-size bypasses and GC-time memory backstop**.

### 2. Uncatchable stops

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (catch_pcall_*:diagnostic, catch_xpcall_*:diagnostic, catch_pcall_wall:diagnostic_blocking_helper):** pcall and xpcall catch step/depth/value errors and reach the continuation helper. Host heap/wall kills do not continue. Coroutine is absent in the default surface as well as policy. **Read upstream ([LuaGuide], 2026-11-14):** the documented limits are catchable; no public sticky-stop option was found in the pinned package inspection.

```jsonl
{"case":"catch_pcall_steps:diagnostic","outcome":"ok","detail":"continued","steps":1000000,"continued":true,"beam_survived":true}
{"case":"catch_xpcall_value:diagnostic","outcome":"ok","detail":"continued","steps":0,"continued":true,"beam_survived":true}
{"case":"catch_pcall_wall:diagnostic_blocking_helper","outcome":"wall_time_exceeded","detail":"host Task killed at 2000 ms","steps":null,"beam_survived":true}
```

Verdict: **does not fit: pcall and xpcall catch runtime stops**.

### 3. Escape paths

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (escape_01 through escape_16, string_methods, fixed_names:diagnostic):** the fresh environment refuses loaders, OS/I/O/debug, GC, raw/metatable operations and unlisted globals. String dump is nil. Default sandbox diagnostics retain extra functions, including sandboxed loader stubs; their function type alone is not evidence of executable loader access.

```jsonl
{"case":"unlisted","outcome":"unlisted_name","detail":"Lua runtime error: unlisted name: not_in_policy","steps":null,"continued":false,"beam_survived":true}
{"case":"string_methods","outcome":"ok","detail":[["dump","nil"],["format","0.33"],["sub","bc"]],"steps":0,"continued":false,"beam_survived":true}
```

Verdict: **fits with fresh environment and restricted string metatable**.

### 4. Allow-list fit

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (enumeration, host_allowlist_audit, fixed_names:diagnostic):** inside enumeration, host environment/shared-metatable inspection and fixed-name/value probes agree on the draft string/table/math and global names listed in the probe README, with helper_echo and no pcall under policy. Diagnostic pcall is an explicit addition. **Observed (probe.exs environment construction):** fresh library/global tables and restricted string metatable use internal Lua.VM.State operations; the public constructor offers deny-list sandboxing. A deny-list alone is not accepted.

```jsonl
{"case":"host_allowlist_audit","outcome":"ok"}
```

Verdict: **fits with version-coupled internal state construction**.

### 5. Determinism of a policy-only source

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (determinism:with_pcall, determinism_pure, fresh-BEAM checker):** pure computation agrees; function tostring identity differs. Mixed-key traversal happened to match, not a promised canonical order. The sparse-table length is 1; numeric strings include 1.0e15 and 0.3333333333333333; division by floating zero formats as 1.0e308, unlike PUC infinity and luerl's error. Integer overflow wraps signed 64 bits. Patterns return aXbX/capture 12 and 17-digit formatting agrees with PUC. Error text differs between providers. **Proposal:** raw identity/order-dependent call sequences can break RC-62 replay; pin semantics, remove unordered traversal and identity formatting, restrict sparse-array/numeric domains, and compare normalized error codes rather than provider prose.

```jsonl
{"case":"determinism_pure","outcome":"ok","detail":"500500","steps":999,"continued":false,"beam_survived":true}
```

Verdict: **fits with replay-domain narrowing and runtime identity**.

### 6. Plain data and errors

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (plain_empty, plain_nested, plain_function, plain_nested_function, plain_cycle, plain_error):** normal/empty plain values pass; functions and cycles are refused by host validation. Threads are unavailable. Host result bounds and sanitization are necessary. **Observed (probe.exs serializer):** unsupported runtime values fall through to refusal; not every userdata/reference type was constructible and separately exercised.

```jsonl
{"case":"plain_empty","outcome":"ok","detail":[],"steps":0,"continued":false,"beam_survived":true}
{"case":"plain_function","outcome":"error","detail":"non_plain_value","steps":null,"continued":false,"beam_survived":true}
{"case":"plain_error","outcome":"error","detail":"Lua runtime error: fixed failure (at probe:1)","steps":null,"continued":false,"beam_survived":true}
```

Verdict: **fits with host plain-data validation and sanitization**.

### 7. Cost

Rerun in the prepared candidate scratch directory: `mix run probe.exs > run.jsonl`.

**Observed (cost_recipe:cost, cost_pure:cost; 200 requests):** run-1 median/p95 are 974/1,103 microseconds for the 200-entry recipe and 162/195 for sum/format 1,000. First workload requests are 1,117/245 microseconds. First cold-in-BEAM evaluation is 35,953 microseconds (39,431 in the second BEAM). Includes fresh Task/state/environment, parse/evaluate/validation; excludes BEAM OS startup and JSON-line printing. No product latency SLO was supplied.

```jsonl
{"case":"cost_recipe:cost","outcome":"ok","detail":{"first_evaluation_us":1117,"median_us":974,"p95_us":1103,"runs":200},"steps":199}
{"case":"cost_pure:cost","outcome":"ok","detail":{"first_evaluation_us":245,"median_us":162,"p95_us":195,"runs":200},"steps":999}
```

Verdict: **fits with measured latency budget**.

### 8. Build and maintenance

Rerun in the prepared candidate scratch directory: `mix deps.get && mix compile --warnings-as-errors`.

**Observed (scratch Mix build and fetched tarball):** Elixir 1.20.4 / OTP 29 compiled 63 package files without package warnings. Shipped LICENSE contains Apache License 2.0. Source is a standalone Elixir parser/compiler/VM, not a luerl wrapper; luerl is benchmark-only. _VERSION reports Lua 5.3, not full compatibility. **Read upstream ([LuaHex], [LuaReleases], [LuaAdvisories], 2026-11-14):** Apache-2.0 metadata, empty runtime requirements; releases 1.0.2 on 2026-07-29, 1.0.1 on 07-16, 1.0.0 on 07-15; published advisories returned empty. Metadata's repository redirects to deviceio/lua. **Read upstream ([LuaIssues], 2026-11-14):** open reports include string caps (#425), instruction accounting (#411), retention (#429); only the four string paths were independently reproduced here.

```text
cf14ab77c27f1acf2fb933b82530bd728dab8a69e7a05757e21a3b49180d4690  lua-1.0.2.tar
```

Verdict: **fits with pinned toolchain**.

## Candidate 2: Hex luerl 1.5.1, inside the VM

### 1. Limits

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (limit_steps and repeat samples; reduction_poll_short_overshoot; empty_loop:trace):** the 1,000,000 reduction target stops around 28.7–29.7 million with differing counts; a finite program succeeds at about 2.6 million. Trace emits only current_line/fcall for an empty loop. **Read upstream ([LuerlSandbox], [LuerlEmul], 2026-11-14):** 100 ms process-reduction polling is host enforcement, not a deterministic runtime instruction counter; no native step/depth/value budget was found. **Observed (native_depth_250, native_value_2m, returned_value_2m):** depth 250 and 2 MiB construction succeed, with host rejection on oversized return. Shared local-function recursion errors undefined function nil; explicit-local recursion is supplementary. **Observed (limit_value:*_binary_accounting):** default binary accounting loses the evaluating BEAM to the RSS guard in both runs; include_shared_binaries:true stops the worker with BEAM survival in both. Both receive kill:true and the same heap target. This is still a GC-time backstop, not a hard quota. Earlier exit 137 remains unexplained.

```jsonl
{"case":"limit_steps","outcome":"steps_exceeded","detail":"host BEAM reductions poll killed runner (not runtime steps)","steps":null,"beam_survived":true,"include_shared_binaries":true,"os_peak_rss_kib":105596}
{"case":"limit_depth","outcome":"error","detail":"undefined function nil","steps":null,"beam_survived":true,"include_shared_binaries":true,"os_peak_rss_kib":107348}
{"case":"limit_value:default_binary_accounting","outcome":"memory_exceeded","detail":"outer OS RSS watchdog killed BEAM","steps":null,"beam_survived":false,"include_shared_binaries":false,"os_peak_rss_kib":527292}
{"case":"limit_value:shared_binary_accounting","outcome":"memory_exceeded","detail":"host runner max_heap_size GC-time kill","steps":null,"beam_survived":true,"include_shared_binaries":true,"os_peak_rss_kib":127380}
```

Verdict: **does not fit: no runtime step budget and default binary-accounting BEAM loss**.

### 2. Uncatchable stops

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (catch_pcall_steps/memory/value:diagnostic, catch_pcall_depth:explicit_local, wall diagnostics):** host kills do not reach continuation. Shared recursive sugar instead raises an ordinary catchable nil-function error and continues; that is not a caught depth refusal. xpcall/coroutine diagnostics report unlisted names; those catchers are unavailable, not demonstrated safe. No uncatchable deterministic runtime step stop exists to test.

```jsonl
{"case":"catch_pcall_steps:diagnostic","outcome":"steps_exceeded","detail":"host BEAM reductions poll killed runner (not runtime steps)","steps":null,"continued":false,"beam_survived":true}
{"case":"catch_pcall_depth:diagnostic","outcome":"ok","detail":"continued","steps":null,"continued":true,"beam_survived":true}
{"case":"catch_pcall_depth:explicit_local","outcome":"memory_exceeded","detail":"host runner max_heap_size GC-time kill","steps":null,"continued":false,"beam_survived":true}
```

Verdict: **does not fit: no uncatchable runtime step limit exists**.

### 3. Escape paths

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (escape_01 through escape_16, fixed_names:diagnostic, string_methods, host_audit:default):** fresh-policy loaders, OS/I/O/debug, GC and raw/metatable names refuse; string dump is nil. Default luerl_sandbox retains clock/date, random, print, debug and metatable operations. Several blocked names are string sandboxed markers, not executable capabilities.

```jsonl
{"case":"unlisted","outcome":"unlisted_name","detail":"unlisted name: not_in_policy","steps":null,"continued":false,"beam_survived":true}
{"case":"string_methods","outcome":"ok","detail":[["dump","nil"],["format","0.33"],["sub","bc"]],"steps":null,"continued":false,"beam_survived":true}
```

Verdict: **fits with fresh environment and restricted string metatable**.

### 4. Allow-list fit

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (public_G_swap):** setting _G through luerl:set_table_keys gives type(io)=table but type(_G.io)=nil, so global resolution was not replaced. **Observed (enumeration:explicit_local, host_audit:policy, fixed_names:diagnostic; checker):** three paths agree on the reduced surface using internal state/global/string-metatable replacement. Missing draft functions are string.pack, packsize, unpack, table.move and math.ult. The fresh _ENV self-alias differs from default _G. Shared recursive enumeration fails; its explicit-local version is supplementary, not a rewritten shared case.

```jsonl
{"case":"public_G_swap","outcome":"ok","detail":[[1,"table"],[2,"nil"]],"steps":null,"continued":false,"beam_survived":true}
```

Verdict: **does not fit: five draft-policy functions absent**.

### 5. Determinism of a policy-only source

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (determinism:diagnostic, determinism_component:*, determinism_pure):** seven isolated components agree across fresh BEAMs. Shared broad source errors on 3//0.0. next returns 2,7,false,a,z but generic-for pairs stops at the false key, returning only numeric keys. Tostring identities happened to match. Sparse length is 1; math.maxinteger+1 returns 9223372036854775808 instead of signed-64 wrap. Numeric strings resemble lua 1.0.2, not PUC's default formatting; patterns/17-digit format match the listed simple examples. Ordinary errors differ from both peers. **Proposal:** runtime switching or order-dependent callback sequences can break RC-62 replay; pin identity, narrow traversal/numeric/array/error semantics, and do not infer compatibility from repeatable errors.

```jsonl
{"case":"determinism:diagnostic","outcome":"error","detail":"bad arithmetic '//' on 3,0.0","steps":null,"continued":false,"beam_survived":true}
{"case":"determinism_component:traversal","outcome":"ok","detail":[["next","2,7,false,a,z"],["pairs","2=3,7=4"]],"steps":null,"continued":false,"beam_survived":true}
{"case":"determinism_component:integer_overflow","outcome":"ok","detail":9223372036854776000,"steps":null,"continued":false,"beam_survived":true}
```

Verdict: **fits with runtime-specific semantics and replay-domain narrowing**.

### 6. Plain data and errors

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (plain_empty/nested/function/nested_function/cycle/error, pcall_empty:diagnostic):** host validation accepts normal/empty data, rejects functions/cycles, sanitizes errors. Threads are unavailable. Empty pcall return diagnostics produce package function_clause, not successful empty-return semantics. **Observed (probe.exs serializer):** non-plain runtime representations fall through to refusal; not every type was separately constructible. Refusal classification is message-based and spoofable.

```jsonl
{"case":"plain_empty","outcome":"ok","detail":[],"steps":null,"continued":false,"beam_survived":true}
{"case":"plain_function","outcome":"error","detail":"non_plain_value","steps":null,"continued":false,"beam_survived":true}
{"case":"plain_error","outcome":"error","detail":"fixed failure","steps":null,"continued":false,"beam_survived":true}
{"case":"pcall_empty:diagnostic","outcome":"error","detail":"package system error: function_clause","steps":null,"continued":false,"beam_survived":true}
```

Verdict: **fits with host plain-data validation and sanitization**.

### 7. Cost

Rerun in the prepared candidate scratch directory: `python3 run.py > run.jsonl`.

**Observed (200-request cost loops):** recipe median/p95 101,002/101,159 microseconds, pure 100,999/101,112; first workload requests 101,302/100,338. Cold-in-BEAM evaluation 134,369 microseconds, second run 124,068. Includes fresh Task/state/environment and limiter polling, excludes OS startup/printing. **Read upstream ([LuerlSandbox], 2026-11-14):** the 100 ms poll sleep precedes noticing a completed runner, explaining the latency floor. These are sandbox-with-limiter costs, not bare interpreter timings.

```jsonl
{"case":"cost_recipe:cost","outcome":"ok","detail":{"first_evaluation_us":101302,"median_us":101002,"p95_us":101159,"runs":200},"steps":null}
{"case":"cost_pure:cost","outcome":"ok","detail":{"first_evaluation_us":100338,"median_us":100999,"p95_us":101112,"runs":200},"steps":null}
```

Verdict: **fits with 101 ms sandbox latency budget**.

### 8. Build and maintenance

Rerun in the prepared candidate scratch directory: `mix deps.get && mix compile`.

**Observed (scratch build/fetch):** builds on Elixir 1.20.4 / OTP 29 with deprecated-catch/exported-variable package warnings; shipped LICENSE is Apache License 2.0. _VERSION reports Lua 5.3; semantics gaps above remain. **Read upstream ([LuerlHex], [LuerlReleases], [LuerlAdvisories], 2026-11-14):** Apache-2.0 metadata, no Hex runtime requirements; release 1.5.1 on 2025-12-03, 1.4.1 on 2025-05-08; repository not archived, last push 2026-10-24; published advisory API returns empty. Empty advisories are not absence of defects.

```text
abf88d849baa0d5dca93b245a8688d4de2ee3d588159bb2faf51e15946509390  luerl-1.5.1.tar
```

Verdict: **fits with OTP 29 package warnings accepted**.

## Candidate 3: PUC Lua 5.4.9 outside the VM over a Port

### 1. Limits

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (limit_steps/depth/memory/value, fresh_process_comparison):** count-hook granularity is one Lua instruction; loop stops at 1,000,000, depth at step 601, string at step 103, allocation at step 31,476 in both completed runs. The maintained C host enforces depth 200, a 16 MiB live-allocation cap and 1 MiB strings/results; BEAM survives. **Observed (host.c allocator/hook inspection):** allocation refusal is checked per allocation, but live-memory pressure and GC timing can change when it happens; treat memory refusal as a recorded host outcome despite these equal samples. Step/depth/string bounds are runtime decisions at the pinned build. Wall timer and 256 MiB OS address limit are host outcomes, not recomputed replay decisions. TString layout coupling is a maintenance condition, not a stable public API.

```jsonl
{"case":"limit_steps","outcome":"steps_exceeded","detail":"steps_exceeded","steps":1000000,"continued":false,"beam_survived":true}
{"case":"limit_depth","outcome":"depth_exceeded","detail":"depth_exceeded","steps":601,"continued":false,"beam_survived":true}
{"case":"limit_memory","outcome":"memory_exceeded","detail":"memory_exceeded","steps":31476,"continued":false,"beam_survived":true}
{"case":"limit_value","outcome":"value_size_exceeded","detail":"value_size_exceeded","steps":103,"continued":false,"beam_survived":true}
```

Verdict: **fits with maintained C host and recorded host outcomes**.

### 2. Uncatchable stops

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (catch_pcall_steps/depth/memory/value; catch_pcall_wall:diagnostic_blocking_helper):** sticky host-stop state, C pcall replacement and hook re-erroring prevent continuation. xpcall/coroutine catchers are absent under policy. **Observed (coroutine_hook:diagnostic_coroutine):** count hook follows the diagnostic child; shared stop is observed at 1,000,001 after the main thread resumes. Coroutine is not admitted. **Observed (negative control recorded in probe README):** disabling sticky rethrow and post-stop hook protection reaches continued:true; restoring safeguards removes that continuation.

```jsonl
{"case":"catch_pcall_steps","outcome":"steps_exceeded","detail":"steps_exceeded","steps":1000000,"continued":false,"beam_survived":true}
{"case":"coroutine_hook:diagnostic_coroutine","outcome":"steps_exceeded","detail":"steps_exceeded","steps":1000001,"continued":false,"beam_survived":true}
{"case":"catch_pcall_wall:diagnostic_blocking_helper","outcome":"wall_time_exceeded","detail":"Port killed at 2000 ms","steps":null,"beam_survived":true}
```

Verdict: **fits with sticky stops and C pcall replacement**.

### 3. Escape paths

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (escape_01 through escape_16, fixed_names, string_methods, host_allowlist_audit):** fresh environment and restricted shared string metatable refuse unlisted loaders, OS/I/O/debug, GC and raw/metatable operations. Missing string dump is nil; unlisted globals use a fixed error. **Observed (unlisted_nil):** alternate nil-global behavior was tested but is not proposed. No syscall/filesystem/network namespace isolation was tested or claimed.

```jsonl
{"case":"unlisted","outcome":"unlisted_name","detail":"unlisted name: not_in_policy","steps":1,"continued":false,"beam_survived":true}
{"case":"string_methods","outcome":"ok","detail":[["dump","nil"],["format","0.33"],["sub","bc"]],"steps":17,"continued":false,"beam_survived":true}
```

Verdict: **fits with fresh environment and restricted string metatable**.

### 4. Allow-list fit

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (enumeration, host_allowlist_audit, fixed_names):** the fresh C-created environment contains the draft named string/table/math functions, scalar globals, helper_echo and sticky C pcall. Shared string __index points only at the fresh listed string table. The three paths agree for those names; policy excludes xpcall/coroutine and raw/metatable/loaders. **Proposal:** the narrower admission below still needs its own tests; the current broad-draft probe is not evidence those wrappers already exist.

```jsonl
{"case":"host_allowlist_audit","outcome":"ok"}
```

Verdict: **fits with C-host allow-list construction**.

### 5. Determinism of a policy-only source

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (determinism and determinism_pure across fresh processes/BEAMs):** pure computation agrees; broad traversal and pointer tostring identities differ. Sparse length is 1; default number strings include 1e+15 and 0.33333333333333; 3//0.0 formats inf; signed-64 overflow wraps. Patterns give aXbX/capture 12; format %.17g returns 0.33333333333333331. Error text includes fixed chunk probe, not host paths, but differs from peers. **Proposal:** raw order/identity can change RC-62 recorded callback order; remove unordered traversal and identity formatting, pin build/numeric semantics, prohibit unsupported sparse-array assumptions, and normalize errors.

```jsonl
{"case":"determinism_pure","outcome":"ok","detail":"500500","steps":2010,"continued":false,"beam_survived":true}
```

Verdict: **fits with replay-domain narrowing and pinned build**.

**Supplementary observed (seed_probe.py, 50 fresh OS processes per build):**

```jsonl
{"candidate": "puc-5.4.9", "case": "seed:host", "outcome": "ok", "steps": null, "detail": {"fresh_processes": 50, "distinct_pairs_orders": 50, "distinct_next_orders": 50, "distinct_table_identities": 50}}
{"candidate": "puc-5.4.9", "case": "seed:host-fixed-seed", "outcome": "ok", "steps": null, "detail": {"fresh_processes": 50, "distinct_pairs_orders": 1, "distinct_next_orders": 1, "distinct_table_identities": 50}}
```

**Read upstream ([LuaState], 2026-11-14) and observed pinned-source inspection:**
the guarded function-like macro is `luai_makeseed(L)`; its default function
hashes time with the state address, a local-variable address and lua_newstate's
address (heap/stack/function, explicitly ASLR-mixed). The build option
`-D'luai_makeseed(L)=0'` bypasses those seed inputs, not all pointer identity.
LUAI_HASHLIMIT is not that override. **Observed (optional fixed build):**
one traversal order but still 50 identities; this supports string-hash seed
as a cause for this string-key workload, not all possible traversal variation.
This is a compile flag, not a fork. **Proposal:** keep it optional; fixed hashing
can weaken collision resistance, and ordered traversal remains the admission
rule rather than relying on this finite test.

Rerun supplement: `sh build.sh && LUA_FIXED_SEED=1 sh build.sh && python3 seed_probe.py`.

### 6. Plain data and errors

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (plain_empty/nested/function/nested_function/cycle/result_size, plain_thread:diagnostic_coroutine, plain_error):** empty/nested values pass; functions, nested functions, cycles, diagnostic threads and oversized/nonfinite outputs refuse. Serializer uses bounded sorted key/value arrays and rejects unsupported keys/values; no userdata/reference producer is granted. Ordinary external errors are reduced to runtime error; internal diagnostic text uses fixed chunk probe. These checks do not make attacker-authored text a secrecy boundary.

```jsonl
{"case":"plain_empty","outcome":"ok","detail":[],"steps":2,"continued":false,"beam_survived":true}
{"case":"plain_function","outcome":"error","detail":"non_plain_value","steps":2,"continued":false,"beam_survived":true}
{"case":"plain_error","outcome":"error","detail":"runtime error","steps":3,"continued":false,"beam_survived":true}
```

Verdict: **fits with bounded C-host serialization**.

### 7. Cost

Rerun in the prepared candidate scratch directory: `elixir driver.exs > run.jsonl`.

**Observed (200-request loops):** recipe median/p95 2,329/2,619 microseconds, pure 93/133. First requests 645/153, fresh-process evaluation 2,297/2,327 microseconds. OS open-through-readiness-and-close median/p95 1,494/1,844 microseconds, including prlimit exec before a Lua state exists. Workload costs include fresh Lua state, parse, execution, serialization and Port/JSON overhead in an already-open host process. No product latency SLO was supplied.

```jsonl
{"case":"cost_recipe:cost","outcome":"ok","detail":{"first_outcome":"ok","first_request_us":645,"fresh_process_evaluation_us":2297,"median_us":2329,"p95_us":2619,"runs":200},"steps":1606}
{"case":"cost_pure:cost","outcome":"ok","detail":{"first_outcome":"ok","first_request_us":153,"fresh_process_evaluation_us":2327,"median_us":93,"p95_us":133,"runs":200},"steps":2010}
{"case":"os_process_start","outcome":"ok","detail":{"command":"prlimit exec host through readiness line; no Lua state yet; 200 runs","median_us":1494,"p95_us":1844},"steps":null}
```

Verdict: **fits with measured Port latency budget**.

### 8. Build and maintenance

Rerun in the prepared candidate scratch directory: `sh build.sh`.

**Observed (checksum-checked scratch build):** Linux C compiler/make/ar, libm/libdl, curl/tar/sha256sum, prlimit, Elixir 1.20.4 / OTP 29 build/run the static Lua library and small C host; host compiles with -Wall -Wextra -Werror. ar emits a harmless ignored-u-modifier notice. Both default and optional fixed-seed builds succeed without editing upstream source. Shipped license is MIT. **Read upstream ([LuaFTP], [LuaLicense], [PucAdvisories], 2026-11-14):** latest 5.4 release is 5.4.9 dated 2026-08-10, previous 5.4.8 dated 2025-05-21; newer 5.5 is outside this comparison. GitHub mirror advisory API returned empty, not a security certification or a complete inventory of upstream bugs. **Proposal:** adoption must pin the C-host/build identity and validate this toolchain on GitHub-hosted runners; local success is not that result.

```text
2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6  lua-5.4.9.tar.gz
```

Verdict: **fits with GitHub-hosted toolchain validation before adoption**.

## Proposed RC-60 admission answers

**Proposal, not implemented admission:** the consumer/admission owns and publishes
an immutable base capability policy; the provider implements it and fails closed
on unknown policy identities. The caller cannot replace that policy or add
arbitrary standard-library names. The only caller additions are explicitly
declared RC-62 module-binding functions under `bindings.<name>`, validated by
the host, with plain arguments/results and declared deterministic or recorded-
outcome semantics. Functions returning unnamed iterators are covered only by
the listing of their parent, as RC-60 specifies.

**Proposal: policy v1 names**, narrowing the observed draft:
- `string.byte char find format gmatch gsub len lower match pack packsize rep
  reverse sub unpack upper` (each qualified with string).
- `table.concat insert move pack remove sort unpack` (each qualified with table).
- `math.abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger
  min mininteger modf pi rad sin sqrt tan tointeger type ult` (qualified with math).
- Globals `ipairs select type tostring tonumber error assert pcall`.
  Remove pairs/next in v1: only dense-array ipairs/numeric ordered iteration.
  A later ordered-map helper needs its own named/versioned admission and tests.
- `tostring` rejects tables/functions/threads/userdata; `string.format`
  accepts scalar text/numbers only and rejects pointer/identity formatting
  (including %p and implicit identity via %s). Pcall is exclusively the
  sticky-stop C replacement, never upstream catchable pcall.
- Mandatory proposed helpers `helpers.json_encode`, `helpers.json_decode`,
  `helpers.text_normalize`, `helpers.time_value`. Time is a value in recorded
  input, not a clock read. Canonical JSON/Unicode/normalization versions are
  part of policy identity. Only helper_echo identity plumbing was probed;
  these production helpers are proposals requiring implementation/tests.
- No coroutine, xpcall, load/loadstring/loadfile/dofile/require/package, os/io,
  debug, print, collectgarbage, get/setmetatable, raw operations, string.dump,
  math.random/randomseed, or implicit filesystem/network/process/clock access.
  Environment syntax is not a grant to the original global environment.
  New lookup paths and returned values must undergo the same capability tests.

**Proposal: replay domain:** only dense arrays may rely on table length; map
iteration must not determine recorded call order. Pin numeric widths, formatting,
locale and runtime/build identity; reject nonfinite plain outputs and specify
integer overflow/float behavior. Error codes are stable policy outcomes, not
provider error prose. The Piece admission must say how these restrictions are
enforced and test them; namespace removal alone does not enforce arbitrary
Lua operator behavior. These narrowed wrappers/domain checks were not built
or tested by this broad-draft spike.

**Proposal: identity:** `policy-v1:sha256:<digest>` identifies canonical UTF-8
JSON with sorted fully qualified capability names, wrapper semantics versions,
helper code/schema identities, bounds, and sorted caller-binding descriptors
(module identity/version or content SHA-256, exported function/arity, namespace,
plain-data schema and effect/replay classification). Record runtime version,
release tarball SHA-256, C-host source SHA-256 and build options (including seed
variant) alongside that policy identity. Any binding implementation change
changes identity even when its name stays the same. Record identities and
host outcomes with the RC-62 call order, and reject replay mismatches.

**Proposal: unlisted-name outcome:** normalized `unlisted_name` with fixed text
`unlisted name: <name>`, observed by all three unlisted-global probes.
Do not pretend a missing table field already errors: observed missing string
dump/method lookup yields nil. Admission must either define absent nonfunction
fields as nil followed by normalized refusal on use, or add/test strict
library-field lookup wrappers so a capability-name use gets the fixed error.
The fixed error is the proposed public outcome; those stricter wrappers are
not claimed implemented here.

## If the owner instead chooses an in-VM runtime

**Read repository architecture (2026-11-14):**
https://github.com/balungpisah/elzoo/blob/main/docs/architecture.md#otp-lifecycle-and-isolation
states OTP supervision is failure containment/restart, not a security sandbox;
hostile input or independent limits require an OS boundary unless an explicit
decision and integration test justify the exception.

**Proposal for owner decision:** explicitly accept or reject replacing that
boundary, name the hostile-input/threat/resource model and residual whole-node
failure risk, and require a separate prerequisite closing deterministic
uncatchable step/value limits before admitting either in-VM candidate. Present
evidence does not justify that exception. Name the Piece integration test
`hostile_lua_cannot_continue_or_kill_vm_test`: run a separately monitored BEAM
containing the proposed supervised adapter plus an independent heartbeat/canary;
exercise bare/protected infinite loops, recursion, allocation, binary growth,
blocking helpers, escape paths and restart storms; assert named refusal,
no post-stop helper effect, live canary/VM, no orphan evaluator, bounded cleanup
and deterministic step results after restart. Include shared-binary accounting
and every newly reachable catcher. Monitor the whole BEAM externally so its
death is a test failure, not a vanished assertion. This test is proposed,
not run; supervision alone is not its substitute.

## Not run, and why

**Observed/not run (probe coverage):** no WebAssembly candidate: optional and
three required candidates already compared. No GitHub-hosted runner build or
hosted check was run here; local toolchain results do not substitute for it.
No exhaustive escape, syscall, namespace, all-library-input or hostile native
helper search: finite probes only. No production helper/module-binding system,
policy-v1 narrowed wrappers or Piece was built; this deliverable precedes
admission/provider adoption. No guarantee across hardware/compiler/runtime
versions was tested, and not all userdata/reference constructors were exposed.

**Observed (earlier luerl whole-suite attempts):** the first exit 137 remains
unexplained; kernel logs were unavailable and no before/after OOM baseline
identified its cause. An additional earlier whole-suite RSS stop occurred even
with shared-binary accounting. Final per-case A/B observations do not erase it.

**Observed (PUC download/build):** direct lua.org archive transfer failed with
TLS EOF/reset while the index remained readable through the web fetcher.
A NetBSD distfile mirror supplied bytes matching the official SHA-256; source
and mirror commands are in the probe README. No alternative bytes were trusted.
The optional fixed-seed experiment is not a hash-flood resistance test.

**Observed (negative controls recorded in probe README):** lua/luerl policy
audits fail after adding print; PUC catches a continuation when sticky
safeguards are disabled; changes were restored. No provider, registry, root
dependency or Piece changes are made by this record.

## Dated upstream references

All references below were read on **2026-11-14**; source-file inspection uses
the checksum-pinned package in addition to the linked upstream documentation.
Empty advisory lists mean only no published advisories returned by that API.

[LuaHex]: https://hex.pm/api/packages/lua/releases/1.0.2
[LuaGuide]: https://hexdocs.pm/lua/sandboxing.html
[LuaReleases]: https://api.github.com/repos/deviceio/lua/releases
[LuaAdvisories]: https://api.github.com/repos/deviceio/lua/security-advisories
[LuaIssues]: https://github.com/deviceio/lua/issues
[LuerlHex]: https://hex.pm/api/packages/luerl/releases/1.5.1
[LuerlSandbox]: https://github.com/rvirding/luerl/blob/v1.5.1/src/luerl_sandbox.erl
[LuerlEmul]: https://github.com/rvirding/luerl/blob/v1.5.1/src/luerl_emul.erl
[LuerlReleases]: https://api.github.com/repos/rvirding/luerl/releases
[LuerlAdvisories]: https://api.github.com/repos/rvirding/luerl/security-advisories
[LuaState]: https://www.lua.org/source/5.4/lstate.c.html
[LuaFTP]: https://www.lua.org/ftp/
[LuaLicense]: https://www.lua.org/license.html
[PucAdvisories]: https://api.github.com/repos/lua/lua/security-advisories
