# ELZ-160 — Pin and exercise the outside-VM Lua provider

## Scope and reuse

- Dependencies: ELZ-033, ELZ-159
- Output: none; non-Piece provider prerequisite for RC-60, release V1B.
- Change class: non-Piece root dependency; full local and hosted check.
- Owned paths: `mix.exs`, `mix.lock`, `registry/providers.json`, `docs/dependencies.md`, `test/elz160_lua_provider_test.exs`, `test/support/elz160_lua_provider_host.c`.

Owner runtime decision, 2026-11-14: reference PUC Lua 5.4.9 outside the VM over
a Port with a small C host, as ELZ-159 recommends. Adopt only the source provider
and exercise its C API here. No sandbox Piece, capability policy, limit host,
module binding or recipe execution is implemented. The proposed v1 names,
`policy-v1:sha256:` identity and `unlisted_name` outcome remain input to the
later Piece admission, not decisions of this task.

Implement only the acceptance groups below. Add no extra features, build
framework, Mix compiler, Make dependency, NIF, fork, vendored library, network
fetch at test time, CI edit or change to `runs-on`. Preserve every existing pin.
No index or generated-file edits belong to the provider implementation.

## Source identity and interface

Add exactly this source-only dependency:

```elixir
{:lua_source,
 git: "https://github.com/lua/lua.git",
 ref: "312b9efaa1061c2c4cad08554dbc1351c3270eef",
 compile: false,
 app: false}
```

Publication preparation checked `git ls-remote` and a scratch clone: upstream tag
`v5.4.9` points to that commit. A standalone Mix project fetched it with these
options; `mix deps.compile` and `mix deps` succeeded, without an OTP app file.
Use the resolved Git entry in `mix.lock`, never a moving tag or branch.

Comparison with the release archive whose SHA-256 is
`2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6`:
all 60 shared `.c`/`.h` files are byte-identical; the tarball has one additional
file, `luac.c`, absent from the mirror. This is equivalence of the library C
and header sources, not whole-release/tree equivalence. The mirror also has
development/test files; do not compile a wildcard over its C files. No Lua
compiler executable is needed. Preserve upstream MIT notices.

Add provider ID `lua_source` using the existing Git provider shape:
`source: "git"`, `package: "lua_source"`, `version: "5.4.9"`,
`revision` equal to the commit above, `url: "https://github.com/lua/lua.git"`,
`reference: "https://github.com/lua/lua/tree/312b9efaa1061c2c4cad08554dbc1351c3270eef"`,
`license: "MIT"`. `lib/elzoo/registry.ex` already checks a Git provider's
URL and 40-character revision against the lock entry; no schema change is needed.
Add a narrow adoption entry to `docs/dependencies.md` with API, failure path,
license and limitations. Libraries are installed by Mix, never copied into
the repository as Elzoo source.

No public Elixir API is added. The adoption check is one root ExUnit test that
builds the installed provider's explicit release library source list into
`liblua.a` in its own disposable build directory, then links the tiny owned
test-support host with `cc` and `ar`. Exclude `lua.c`, tests, and amalgamations.
Use the upstream release library list, not a second Lua implementation.
The host creates a state, loads source, runs via `lua_pcall`, returns a fixed
success/error protocol and always calls `lua_close`. The ExUnit parent launches
it outside the VM through an OTP Port, closes/reaps it and removes build output.
No build helper dependency is needed: standard C tools plus ExUnit suffice for
this provider smoke check. Production artifact packaging belongs to the later
runtime Piece admission; this test-only host must not become that runtime.

## Host Needs and Limits

Needs: Git access during `mix setup`, the repository-pinned Mix/OTP toolchain,
a Linux C compiler and archiver, and the normal disposable full-check services.
Build only in a unique disposable directory; never write binaries into tracked
source or the installed dependency. Bound the build/run check to 120 seconds;
on timeout close the Port and reap the child, report failure rather than skip.
Use only fixed finite source snippets, never hostile unbounded input here.

Telemetry, Config and Control: not applicable; no Piece or running service.
This task establishes finite C-API/build compatibility, not security isolation,
deterministic limits, a sandbox allow-list or reproducibility across platforms.

## Named acceptance groups

1. **`pinned_source_and_license`**: clean `mix setup` fetches the exact Git revision; provider/lock URL and revision agree; actual `LUA_RELEASE` is `Lua 5.4.9`; MIT notices remain available; no existing pin changes or copied Lua sources. Registry checks accept the record without modifying their schema.
2. **`static_library_and_port_success`**: compile the explicit library list with warnings enabled, archive it, link the host with warnings as errors, and run a finite chunk returning integer 42. Assert the host's fixed result and successful exit, not merely compilation. Record compiler/archiver commands and actual Lua version.
3. **`empty_and_failed_chunk`**: an empty chunk completes with zero results; a malformed chunk reports load failure; `error('probe')` reports protected-call failure. Assert distinct fixed outcomes, no host crash, and cleanup on each path. No provider diagnostics become a claimed public error API.
4. **`hosted_build_is_exercised`**: the root test runs, without skip or cached prebuilt-host substitution, in the exact-head full hosted check on the existing GitHub-hosted runner. Assert actual compilation of this source into the static library and host. Local compilation alone is not this evidence.

## Evidence and gate

Tests only; no Cure law, type-check or security proof is claimed. Upstream owns
Lua parsing/evaluation and the C API; Elzoo owns pinning, the adoption check and
cleanup. Negative control: temporarily change the expected integer result and
show `static_library_and_port_success` fails; restore before the final gate.
Record source identity, commands, exit codes, scenarios and limitations separately.

Run `mix test --warnings-as-errors test/elz160_lua_provider_test.exs`, then
`mix check` and `git diff --check`. Full local `mix check` and full hosted check
are required, never the Piece/spike/docs-only shortcut. If a service or tool is
unavailable, record the exact command and error; do not weaken the test or runner.
One independent review checks the task and exact implementation diff.
