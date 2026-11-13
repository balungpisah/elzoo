# ELZ-159 — Provider-fit record for a bounded Lua runtime (RC-60, first deliverable)

- Dependencies: ELZ-033
- Change class: documents only (AGENTS.md section 1). The record and the probe sources are the deliverable; no executable input of the repository changes.
- Owned paths: `docs/work/ELZ-159-lua-runtime-fit.md` and the directory `docs/work/ELZ-159-probes/`, nothing else.
- Output: no Piece ID. `runtime/lua-sandbox` and `runtime/lua-stdlib` stay on RC-60. Release V1B; bot-platform wave 3, level 1.

## Outcome

RC-60 says that its first deliverable is the provider-fit record, not the Piece. This task writes that record. It compares Lua runtimes against the Contract, the acceptance and the blockers of RC-60 in `docs/plans/release-plan.json`. Read that row before you start. It ends with a recommendation. The owner chooses the runtime (`docs/plans/bot-platform.md`, "Owner decisions that are still open"). After that choice the coordinator publishes the provider-adoption task (`mix.exs`, `mix.lock`, `registry/providers.json`, as ELZ-099 did) and then the Piece task.

Change no file outside the owned paths: no `mix.exs`, `mix.lock`, `registry/`, `lib/`, `test/`, `pieces/`, `.github/`, `scripts/` and no pin. Run each probe in a scratch Mix project or directory outside the checkout, with its own dependencies. Commit the probe sources so that a reviewer can run them again; commit no build output, dependency source or binary.

## Candidates

At least these three. Record the exact version, the source (Hex release, tarball and its SHA-256), the license and how you built it.

1. `lua` 1.0.2 on Hex (Apache-2.0), a Lua 5.3 interpreter in Elixir. Inside the VM.
2. `luerl` 1.5.1 on Hex (Apache-2.0), Lua in Erlang, with `luerl_sandbox`. Inside the VM.
3. The reference Lua 5.4 interpreter (PUC-Rio, latest 5.4 release; MIT) run in a separate OS process, reached from the VM through a `Port`. This is the candidate outside the process boundary of the VM that RC-60 requires. Decide and record how its limits are enforced: for example a small C host built from the release tarball with a counting allocator (`lua_newstate` with an allocation function) and a count hook (`lua_sethook` with `LUA_MASKCOUNT`), against a host-side wall-time kill and an OS limit. Record which limits the runtime counts deterministically and which are host outcomes.

A further candidate (for example a WebAssembly build) is optional. A fork is not assumed (`docs/development/08-upstream-and-forks.md`).

## What the probe records, for each candidate

Use the RC-60 acceptance as the checklist; each item below is one named section of the record with the command, the output and a verdict.

1. **Limits.** An infinite loop, deep recursion, a large allocation and a string bomb each end in a named refusal within the bound, and the host VM survives each case. For each limit: is it counted inside the runtime and deterministic (the same source and input stop at the same point on every run and after a restart of the VM or the OS process), or is it a host outcome (wall time, a memory stop that depends on garbage-collection timing)?
2. **Uncatchable stops.** For `pcall`, `xpcall`, `coroutine.resume` and `coroutine.wrap`: show that the function is not reachable, or that a source that uses it does not continue after a step, memory, call-depth, value-size or wall-time stop. Record the case where a count hook does not follow into a coroutine, if that applies.
3. **Escape paths.** `load`, `loadstring`, `dofile`, `require`, `package`, `os`, `io`, `debug`, `string.dump`, `collectgarbage`, and metatables on shared values (the string metatable). None reaches a runtime function when the policy does not list it. Record the outcome of the use of an unlisted name (for example an error with a fixed text, or nil).
4. **Allow-list fit.** Take the consumer draft of policy version 1 in the RC-60 blockers as the policy. For each candidate, list the names that a source reaches by each path of the contract, found three ways: from inside the sandbox; from the host side through the interface of the runtime (the environment table and each shared metatable); and by probing a fixed list of standard-library names through values. Record each difference from the policy. Say whether the candidate can be made to reach exactly the policy on all three, and how: an allow-list that builds a fresh environment, or a block-list that removes names. A block-list alone does not satisfy the Contract.
5. **Determinism of a policy-only source.** For a source that uses only policy names, compare across candidates and across restarts: table traversal order (`pairs`, `next`), `tostring` of tables and functions, error message text, the length of a table with holes, number formatting, integer and float arithmetic, and string patterns. Say for each difference whether it would make a replay of RC-62 fail, and propose the narrowing (for example an ordered traversal only) for the admission.
6. **Plain data and errors.** Returned data is plain: no function, userdata, thread or reference leaks to the host. No error text holds a host path, a hostname or a process identifier.
7. **Cost.** For one fixed recipe-like source (build a table of 200 plain entries and return it) and one fixed pure function (sum and format 1,000 numbers): the median and the 95th percentile of 200 runs, the start cost of one evaluation, and for candidate 3 the OS process start cost. Name the host machine only by its CPU count and memory size.
8. **Build and maintenance.** Native code and a toolchain that candidate 3 needs on a GitHub-hosted runner, release activity, open security reports, and whether the package builds with the pins in `.tool-versions` and `mix.exs`.

## The record

`docs/work/ELZ-159-lua-runtime-fit.md`:

- one table with a row per candidate and a column for each of the eight sections, with a verdict cell (`fits`, `fits with <named condition>`, `does not fit: <reason>`);
- the recommendation: one runtime, and whether it runs inside the VM or outside it. A runtime inside the VM needs the explicit decision and the integration test that `docs/architecture.md` ("OTP lifecycle and isolation") requires before it is accepted for hostile input: write that decision as a proposal for the owner and name the integration test that the Piece task must have;
- the proposed answers to the open points of the RC-60 blockers: who supplies the policy, how a function that a caller gives enters the policy and its version identity, the names of policy version 1, the form of the version identity and the outcome of an unlisted name;
- what was not run, and why.

If no candidate supports a step limit that the runtime enforces without a fork, stop and report on the issue (RC-60 blocker), with the record so far.

## Acceptance

- The record has the eight sections for each of the three candidates, each with its command, output and verdict, and the recommendation and proposed answers above.
- Each probe source is in `docs/work/ELZ-159-probes/` and runs again from its own README there, outside the checkout.
- Each statement in the record is marked as observed (with the probe that showed it) or as read from an upstream page (with its URL and date). Write "the listed probes pass", not "verified".
- Local gate: `python3 scripts/check-roadmap.py` and `git diff --check`, with exit codes. The hosted check is the docs-only check.

## Limits

This task chooses no runtime, adopts no dependency and builds no Piece. A probe is a finite set of scenarios, not a proof of isolation. No claim that any candidate is a security boundary beyond what the probes show. Telemetry, Config and Control are not applicable.

One worker owns the claimed branch and worktree. One independent review under AGENTS.md section 6.
