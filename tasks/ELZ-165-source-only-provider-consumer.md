# ELZ-165 — Carry source-only providers into copied consumers

## Scope and reuse

- Dependencies: ELZ-160
- Output: none; non-Piece harness prerequisite for native Pieces, release V1B.
- Change class: non-Piece shared harness; full affected local and full hosted check.
- Owned paths: `registry/providers.json`, `lib/elzoo/registry.ex`, `lib/elzoo/export.ex`, `test/support/cure_consumer_case_test_helper.exs`, `test/registry_test.exs`, `test/export_test.exs`, `test/source_only_provider_test.exs`, `test/fixtures/elz165_source_only_provider/**`, `docs/consuming.md`, `scripts/test-ci-change-class.py`, this task file, and its publication row/generated planning views under AGENTS.md section 3.

Coordinator one-PR path: publish and implement this non-Piece change together.
No reusable Piece ID or ready Piece Contract changes. Reuse the installed
ELZ-160 Lua source provider and existing export/copied-consumer harness.
Implement only the named acceptance groups. Add no extra features.

## Interface and behavior

Provider records accept optional boolean `compile` and `app` fields. Mark
`lua_source` with both false; leave its identity and all dependency pins alone.
Missing fields preserve existing provider behavior. Source-only means both
fields are false; do not accept compiler command strings or arbitrary Mix
options through this metadata.

Generated install instructions emit the source-only Git dependency with its
exact URL, revision, `compile: false, app: false`. Do not add a depth option to
this tuple. Preserve existing ordinary Git/Cure and Hex installation text,
runtime policy, receipts and read-only export planning. Piece manifests still
name provider IDs; `dependencies` remain Piece IDs. Native files already fit
the supported `lib/.../native/` source role; do not add `c_src/` support.

The shared copied-consumer helper resolves selected source-only providers from
the outer `Mix.Project.deps_paths()` and adds temporary path dependencies with
`compile: false, app: false` to its generated Mix project. Fail clearly on a
missing checkout. The inner `Mix.Project.deps_paths()` then supplies the same
installed source without fetching, copying or modifying upstream files. Add
only selected source-only providers, never every dependency or the catalogue
application. Preserve existing BEAM-path injection, application startup policy,
only-own-tests selection, runtime isolation and consumer timeouts.

## Host Needs and Limits

Needs: the pinned toolchain, already fetched Lua checkout, Linux `cc`/`ar` and
disposable full-check services. Tests build native outputs in unique disposable
directories, remove them on exit, use finite input and fail rather than skip
when a required tool is absent. Native fixture build/run has a 120-second
deadline and kills/reaps its child on timeout. Do not vendor Lua, write build
outputs into the checkout, or fetch dependencies inside copied tests.

No sandbox, runtime host packaging, new Piece, new dependency/pin, native
compiler framework, CI/runner edit or claim of cold-install/release evidence.
The path dependency is harness checkout reuse only; real consumers install
the pinned Git dependency using their own Mix project and lockfile.
Telemetry, Config and Control: not applicable to this development harness.

## Named acceptance groups

1. **metadata_and_install** — Accept boolean compile/app flags and absent
   defaults, reject malformed flags. Source-only install tuple and receipt
   preserve the pin/options; ordinary-provider and Cure golden text stays
   unchanged. A selection without Lua gets no Lua dependency. Planner writes
   nothing and copies/hashes owned native bytes without reading the checkout.
2. **native_copied_consumer** — A synthetic fixture declares Lua, owns C under
   lib/native and resolves Lua through inner deps_paths. Compile the explicit
   ELZ-160 static-library source list with cc/ar, link the owned host and assert
   success, empty and error outcomes over an OTP Port. This is a normal root
   test, not only a selected new-Piece consumer tag. No new catalogue Piece.
3. **selection_and_isolation** — Exercise the shared consumer helper normally
   and with only_tests_of for the synthetic Piece. A deliberately failing
   dependency test must remain excluded in only-own-tests mode. A missing
   required checkout fails before the subprocess. Lua has no application or
   compiler startup, no root support/prebuilt host is used, no catalogue module
   leaks and source bytes remain unchanged. Existing per-ID/aggregate dispatch
   and startup/configuration tests still pass.
4. **negative_controls** — Temporarily omit each install flag, omit the
   generated source path dependency, remove the checkout mapping and change
   the owned C result; the corresponding tests must fail. Record failures and
   restore every edit before the final gate. No skip or altered expectation
   substitutes for the native execution check.

## Evidence and gate

Finite registry/export/real-process tests and pinned upstream Lua/Mix/OTP
behavior, not a Cure proof or security claim. Document source-only installation
and checkout-reuse limits in docs/consuming.md. One independent review reads
the task and exact implementation diff.

Run focused registry/export/install-configuration/source-only-provider tests,
then `mix check --affected origin/main`, `git diff --check`, roadmap checks
including `--self-test` and `--live`, and the range change classifier. This is
never the Piece/spike/docs-only shortcut. Record unavailable local services
and their exact failures rather than weakening the hosted check.
