# The first release

## Status and scope

This document is the planning input for Elzoo's first release. [release-plan.json](release-plan.json) stays the one canonical planning source. ELZ-388 published this plan; the Level 1 work has since merged. F is [ELZ-403](../../tasks/ELZ-403-first-release-freeze.md). The coordinator assigns IDs to A, X1–X3 and M at publication. Each published task is the Contract of its work. Where a task differs from a sketch below, the task wins.

Wave 9 is the last row of the wave table of [bot-platform.md](bot-platform.md). Its root consumer acceptance [ELZ-379](../../tasks/ELZ-379-wave9-tools-doors-models-money-acceptance.md) merged on `main` as [#933](https://github.com/balungpisah/elzoo/pull/933) at `c6fe7a8f`. Its follow-ups ELZ-380 to ELZ-386 have merged too, the last at `77569285`. The publication of ELZ-387 (#941, [#942](https://github.com/balungpisah/elzoo/pull/942)) merged at `a290e338`. Its build has since merged (Level 0 below). The plan's baseline comes from "What remains after Wave 9" in [bot-platform-wave9.md](bot-platform-wave9.md#what-remains-after-wave-9) and from the `release_gates`, `products` and `jobs` of [release-plan.json](release-plan.json), read at `a290e338`.

The first release is one event that passes three gates together: `V1-ACCEPT`, `V1B-ACCEPT` and `V2-ACCEPT`. `V3-ADMIT` is research only and is not part of it. The plan has five steps, in this order:

1. The repairs that must land first, including ELZ-387, merge (Levels 0 and 1).
2. One documents-only task freezes the selected set and the record formats (Level 2).
3. One root acceptance task passes the three gates on the frozen set (Level 3).
4. Three Piece tasks commit the record fixtures written by the frozen code (Level 4).
5. One task (Level 5) names the release in the consuming documents and in `AGENTS.md` section 4. Its merge commit on `main`, with a green push run, is the **release commit**. It changes no Piece, so its code is the code of the last fixture task's merge. From the release commit on, the new-ID rule of `AGENTS.md` section 4 applies to every ready Contract.

The plan adds no Piece, no script, no CI job and no release mechanism that the repository's documents do not already support.

### Settled owner decisions

These decisions are inputs of the plan, not questions:

1. **No deferred row is waited for (owner, 2026-11-25).** "The first release does not wait for any deferred, demand-led row. Neither a first chat channel nor a payment provider is chosen. They come later as new Pieces, which needs no new ID for any existing Contract."
2. **#930 takes option A (owner, 2026-11-25).** An opt-in run-engine start option, published as [ELZ-387](../../tasks/ELZ-387-run-engine-messages-while-active.md) and built in place before the release. The release depends on it.
3. **Freeze, accept, then fixtures (owner, 2026-11-25, with the decision of 2026-11-21).** "After the release, freeze the selected set and the record formats. Then run V1-ACCEPT, V1B-ACCEPT and V2-ACCEPT. Then commit the record fixtures written by the released code to the tests of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test`. From then on, the new-ID rule of AGENTS.md section 4 applies." The 2026-11-21 note in [bot-platform.md](bot-platform.md#owner-decisions-that-are-still-open) adds that the fixtures come only then: "Not before: no older format exists yet."
4. **In place before the first release (owner, 2026-11-14), and no corner (owner, 2026-11-21, standing).** Until the release commit, a ready Piece that lacks something that clearly belongs to it is extended in place under its ID. After the release commit, a change to accepted inputs, outputs, state, delivery, failure guarantees or Needs gets a new ID. A bug fix that restores the Contract keeps the ID ([AGENTS.md section 4](../../AGENTS.md#4-build)).

### Owner answers (2026-11-25)

The owner answered on 2026-11-25: "All A".

- **Q1 A:** The release commit is the merge of the release mark M, after the freeze, acceptance and fixtures. The new-ID rule starts at that commit.
- **Q2 A:** The release is marked in the documents only: no tag, GitHub release, version change or changelog. This is the owner's ask for M's `AGENTS.md` edit.
- **Q3 A:** #886, #915, #885 with #884, and #701 must land before the freeze as Levels 1e–1i, with their task prerequisites.
- **Q4 A:** X3 pins golden `run/1` records. It does not add a public reader or an extra Level 1 task for one.

## Source boundaries checked (at `main` `a290e338`)

These facts were read at `a290e338`. They are facts, not claims that any release step has run.

- **Gates.** `release_gates` holds `V1-ACCEPT`, `V1B-ACCEPT` and `V2-ACCEPT`. Each is "not published; frozen selected set and independent integrated acceptance required". Each selects the jobs of its `release` whose `stage` is not in `exclude_stages` (`examples-later`, `research`). `V2-ACCEPT` names `V1-ACCEPT` as its prior gate. V1 and V2 require "All selected jobs accepted or exact tested upstream/index resolution reviewed; integrated pinned mix check, source-copy/namespace/schema/provider compatibility and claim-level evidence". V1B requires that "one recipe runs end to end through the engine, the agent and graph patterns and the Lua layer with scripted Adapters, under the pinned mix check", and "does not wait for V1-ACCEPT". `scripts/check-roadmap.py` derives the selected set from the selector alone (`gate_jobs`, lines 134–136). It checks that each job dependency is in the same or an earlier release (line 66), but it does not check the dependencies in Piece manifests. [roadmap.md](roadmap.md) (lines 81–89): "Final release-acceptance issues are admitted only after the selected set is frozen."
- **Selected jobs today.** V1: 113 jobs, 90 published and 23 proposals. V1B: 254 jobs, 227 published (ELZ-387 among them) and 27 proposals. V2: 32 jobs, 21 published and 11 proposals. Excluded: RC-37 to RC-41 (`examples-later`) and RC-33 to RC-36 (`research`). Every issue of a published job is in the state "completed", apart from one open issue, #941 (ELZ-387). Twenty early V1 rows (ELZ-001 to 009, 013 to 021, 025 and 032) have the status "historical-closed; not independently reaccepted here". ELZ-028's status still says "blocked: accepted ELZ-010 and provider-fit decision required", but it merged as [#123](https://github.com/balungpisah/elzoo/pull/123) and `state/lease` is ready. "What remains after Wave 9" also lists ELZ-028 as blocked. Both are stale.
- **Catalogue today.** 176 rows: 152 ready (70 owned by V1 jobs, 75 by V1B jobs, 7 by V2 jobs), 16 not ready but owned by selected jobs, 4 deferred examples and 4 deferred research rows. Two candidate gaps (RC-42, RC-43) are outside the catalogue. Every V1B row is ready. One ready V1 Piece depends on a V1B Piece: `integration/search-data` (ELZ-082) names `state/tenant-isolation` (ELZ-270) in its `piece.json`, since the in-place change of Wave 7 Q7. The gate check does not see this, because it reads job dependencies only.
- **How a consumer takes Elzoo.** [consuming.md](../consuming.md), lines 34–35: "Take Pieces from the latest commit of `main` whose push run of the backend workflow (`symbolic-check.yml`) is green; there is no separate marker branch". Lines 162–169: a changed ready Contract gets a new Piece ID with migration notes, and "There is no silent upgrade, rollback engine or remote registry service". The receipt that `mix elzoo.take` writes (`lib/elzoo/export.ex`, lines 56–68) holds `schema_version` 1, `origin`, `revision` (the commit), `uncommitted_changes`, the selected Pieces, the providers and the file hashes. It holds no version number.
- **What does not exist.** The repository has no Git tag (`git ls-remote --tags origin` lists none), no GitHub release and no changelog file. `mix.exs` line 9 has `version: "0.1.0"`. That is the version of the harness project. No receipt reads it, and a consumer never depends on the `:elzoo` application.
- **Change class.** `docs/consuming.md` is copied into every export and is read by the export tests, so `scripts/ci-change-class.py` (line 56, `READ_BY_CODE`) never counts it as documentation. Any task that edits it takes the full check. `docs/plans/release-plan.json` and the rest of `docs/` count as documentation.
- **Record formats.** [runtime/durable-unit](../../pieces/runtime/durable-unit/README.md), line 35: "The fixed v1 encoding is an OTP external term `{1, data}`". [assembly/run-engine](../../pieces/assembly/run-engine/README.md) records each start option in the control of its `:configure` record and in the fingerprint (lines 67–79, for `expiry_reports`). ELZ-387 adds `messages: :while_active` in the same way. [workflow/pattern-step](../../pieces/workflow/pattern-step/README.md) has closed v1 and v2 maps, and its only fixture is "the fixed unequal `@v1_fixture` in the test" (line 54). [runtime/recipe-test](../../pieces/runtime/recipe-test/README.md), line 365: "The record is read from the version-1 records of the engine; a later record form needs a change here."
- **Integrated evidence already in the full check.** `test/export_test.exs` has "every ready Piece plans into one destination" and the aggregate consumer "all selected sources compile and run outside Elzoo with only upstream code paths". The suite also has `test/cure_record_tags_test.exs`, `test/registry_test.exs` and `test/install_configuration_test.exs`, plus `scripts/check-claims.py`. The Wave 4 to Wave 9 root acceptances are in `test/`. No single recipe in `runtime/recipe-test`'s tests covers a graph, an agent and a Lua tool together. The nearest are "a root graph tool node gives the object of the Lua tool", "an agent calls the Lua tool, which makes one module call" and "an agent child, a decision child and a tool node run in one graph". The Lua tool cases use `"wall_ms" => 500` (`recipe_test_lua_test.exs`, line 242), which is the limit that #547 reports failing under load.
- **Review owed.** `AGENTS.md` section 6 (lines 445–448): "The same reviewer of another model family rechecks `domain/journal`, `domain/metering` and `delivery/dead-letter-store` once". Their pull requests (#698, #696 and #699) carry only their original review records, so the rechecks are still owed. The skip list of the [coordinator guide](../development/13-coordinator.md) holds one row, #798 (`06e50161..fa99ba68`).

## The selected set

The V1, V1B and V2 gate selectors keep their existing logic. They exclude `examples-later`, `research`, `later` and `release`. The 14 proposals in the disposition table move to `later`; the release's own tasks (F, A, X1–X3 and M) and any repairs admitted during the freeze use `release`. Neither stage contributes jobs to the frozen set. Product job lists stay intact; their limits say which parts are not supplied.

### Frozen set at F’s base (`edd27760`)

This snapshot includes ELZ-387, all Level 1 jobs, ELZ-388 (the plan, V2), and the two admitted repairs ELZ-401 and ELZ-402 (V1B, stage `pieces`). F itself is excluded.

| Gate | Selected at the base | Moved to `later` | Frozen jobs | Ready rows |
| --- | --- | --- | --- | --- |
| `V1-ACCEPT` | 113 (90 published, 23 proposals) | 7 (RC-01, RC-04, RC-06, RC-09, RC-17, RC-42, RC-43) | 106 | 70 |
| `V1B-ACCEPT` | 265 (238 published, 27 proposals) | 0 | 265 | 75 |
| `V2-ACCEPT` | 36 (25 published, 11 proposals) | 7 (RC-20, RC-24, RC-27, RC-28, RC-29, RC-30, RC-31) | 29 | 7 |

The lists below are in release-plan order.

#### V1-ACCEPT jobs

```text
ELZ-001 ELZ-002 ELZ-003 ELZ-004 ELZ-005 ELZ-006 ELZ-007 ELZ-008 ELZ-009 ELZ-010
ELZ-011 ELZ-012 ELZ-013 ELZ-014 ELZ-015 ELZ-016 ELZ-017 ELZ-018 ELZ-019 ELZ-020
ELZ-021 ELZ-022 ELZ-023 ELZ-024 ELZ-025 ELZ-026 ELZ-027 ELZ-028 ELZ-029 ELZ-030
ELZ-032 ELZ-033 ELZ-050 ELZ-052 ELZ-053 ELZ-054 ELZ-055 ELZ-083 ELZ-081 ELZ-084
ELZ-087 ELZ-079 ELZ-080 ELZ-085 ELZ-091 ELZ-092 ELZ-097 RC-02 RC-03 RC-05
RC-07 RC-08 RC-10 RC-11 RC-12 RC-13 RC-14 RC-15 RC-16 RC-18
RC-19 RC-26 RC-32 ELZ-094 ELZ-093 ELZ-095 ELZ-082 ELZ-096 ELZ-098 ELZ-099
ELZ-100 ELZ-101 ELZ-104 ELZ-103 ELZ-105 ELZ-107 ELZ-106 ELZ-108 ELZ-109 ELZ-110
ELZ-111 ELZ-112 ELZ-113 ELZ-116 ELZ-119 ELZ-120 ELZ-121 ELZ-128 ELZ-129 ELZ-130
ELZ-131 ELZ-132 ELZ-133 ELZ-134 ELZ-135 ELZ-149 ELZ-151 ELZ-152 ELZ-153 ELZ-154
ELZ-155 ELZ-157 ELZ-158 ELZ-184 ELZ-185 ELZ-244
```

#### V1B-ACCEPT jobs

```text
ELZ-114 RC-44 RC-45 RC-46 RC-47 RC-48 RC-49 RC-50 RC-51 RC-52
RC-53 RC-54 RC-55 RC-56 RC-57 RC-58 RC-59 RC-60 RC-61 RC-62
RC-63 RC-64 RC-65 RC-66 RC-67 RC-68 RC-69 RC-70 ELZ-115 ELZ-117
ELZ-118 ELZ-122 ELZ-123 ELZ-125 ELZ-124 ELZ-126 ELZ-127 ELZ-136 ELZ-141 ELZ-144
ELZ-145 ELZ-146 ELZ-137 ELZ-139 ELZ-140 ELZ-142 ELZ-138 ELZ-143 ELZ-147 ELZ-148
ELZ-150 ELZ-156 ELZ-159 ELZ-160 ELZ-165 ELZ-161 ELZ-162 ELZ-163 ELZ-164 ELZ-166
ELZ-167 ELZ-168 ELZ-169 ELZ-172 ELZ-170 ELZ-171 ELZ-174 ELZ-173 ELZ-175 ELZ-176
ELZ-177 ELZ-178 ELZ-179 ELZ-180 ELZ-181 ELZ-182 ELZ-183 ELZ-186 ELZ-187 ELZ-188
ELZ-189 ELZ-190 ELZ-191 ELZ-192 ELZ-193 ELZ-194 ELZ-195 ELZ-196 ELZ-197 ELZ-198
ELZ-199 ELZ-200 ELZ-201 ELZ-202 ELZ-203 ELZ-204 ELZ-205 ELZ-206 ELZ-207 ELZ-208
ELZ-210 ELZ-211 ELZ-212 ELZ-213 ELZ-214 ELZ-215 ELZ-216 ELZ-217 ELZ-218 ELZ-219
ELZ-220 ELZ-221 ELZ-223 ELZ-224 ELZ-227 ELZ-229 ELZ-230 ELZ-222 ELZ-231 ELZ-232
ELZ-233 ELZ-234 ELZ-225 ELZ-235 ELZ-236 ELZ-237 ELZ-238 ELZ-239 ELZ-240 ELZ-241
ELZ-242 ELZ-243 ELZ-245 ELZ-246 ELZ-247 ELZ-248 ELZ-249 ELZ-250 ELZ-251 ELZ-252
ELZ-253 ELZ-254 ELZ-255 ELZ-256 ELZ-257 ELZ-258 ELZ-259 ELZ-260 ELZ-261 ELZ-262
ELZ-263 ELZ-264 ELZ-265 ELZ-266 ELZ-267 ELZ-268 ELZ-269 ELZ-270 ELZ-271 ELZ-272
ELZ-273 ELZ-274 ELZ-275 ELZ-276 ELZ-278 ELZ-279 ELZ-280 ELZ-281 ELZ-282 ELZ-283
ELZ-284 ELZ-285 ELZ-286 ELZ-277 ELZ-287 ELZ-288 ELZ-289 ELZ-290 ELZ-292 ELZ-293
ELZ-294 ELZ-295 ELZ-296 ELZ-298 ELZ-299 ELZ-300 ELZ-301 ELZ-302 ELZ-303 ELZ-291
ELZ-305 ELZ-306 ELZ-307 ELZ-308 ELZ-309 ELZ-315 ELZ-311 ELZ-312 ELZ-310 ELZ-318
ELZ-317 ELZ-322 ELZ-325 ELZ-328 ELZ-329 ELZ-330 ELZ-331 ELZ-332 ELZ-333 ELZ-334
ELZ-335 ELZ-337 ELZ-338 ELZ-339 ELZ-340 ELZ-341 ELZ-342 ELZ-343 ELZ-344 ELZ-345
ELZ-346 ELZ-347 ELZ-348 ELZ-349 ELZ-351 ELZ-352 ELZ-354 ELZ-355 ELZ-357 ELZ-358
ELZ-359 ELZ-360 ELZ-361 ELZ-362 ELZ-363 ELZ-364 ELZ-368 ELZ-369 ELZ-370 ELZ-371
ELZ-372 ELZ-373 ELZ-374 ELZ-375 ELZ-376 ELZ-377 ELZ-380 ELZ-381 ELZ-382 ELZ-383
ELZ-384 ELZ-385 ELZ-386 ELZ-387 ELZ-389 ELZ-390 ELZ-391 ELZ-393 ELZ-394 ELZ-396
ELZ-397 ELZ-398 ELZ-400 ELZ-401 ELZ-402
```

#### V2-ACCEPT jobs

```text
ELZ-031 RC-21 RC-22 RC-23 RC-25 ELZ-297 ELZ-304 ELZ-316 ELZ-313 ELZ-314
ELZ-319 ELZ-320 ELZ-321 ELZ-323 ELZ-324 ELZ-326 ELZ-327 ELZ-336 ELZ-350 ELZ-353
ELZ-365 ELZ-366 ELZ-367 ELZ-378 ELZ-379 ELZ-388 ELZ-392 ELZ-395 ELZ-399
```

The 152 ready rows are grouped by the release of their owning job. These hashes are the manifest bytes at F’s base, before acceptance and the fixtures.

#### V1 ready rows

| Piece | `manifest_sha256` |
| --- | --- |
| `assembly/durable-job` | `5716b11e17c7ccdf3c0913c876e64263f483ee93b75af2ebcc2a949dce1d8056` |
| `assembly/http-job` | `f40d390395f38469b8c54c1c4441b9a736c168b9356d13ad0e89c1d90c75cc0d` |
| `assembly/ingest-dedup-accumulate` | `c4ea134d9de381d4187e310e6e4417d1fdda495ecb8389ef3f1b257c672e4f21` |
| `assembly/ingest-json-unit` | `18636ead1b9dcd9d5d099bb24203fb86033580f384ad3230bae7e2238416e441` |
| `assembly/request-route-retry` | `ffedf5eddca3e5583c51e4ff5baa656118871dacb276fa63cfa673177d81dba3` |
| `core/assembly` | `d0968bd54175e3e82ac6d86676f1835457ec9f3c43dfebcb0f2002860a3935c4` |
| `core/edge` | `ee75c26f1e4c9fe893354de6d51f4cb6e5ef79f0c7e7ce2dc6e25f8243035556` |
| `core/effect` | `7871cfd927e328453cdff0d3f4a9ac83c358059f9017c3de9b8ede351dab5317` |
| `core/envelope` | `818e8f6be6996189d400935cd9480321d25dd74d0196294da1487cf545739629` |
| `core/operator` | `88551ff27503570e577083a64f2b6b289916c5e0ae2a0545da73550af9e866e3` |
| `core/port` | `f20ebc536e00ae2dff18bc32a8ec47028e1319354ed4ae1abe1ab470b20c2645` |
| `core/selection` | `983ba27f4259caa1da2667333e635a79ddd1006827daf8596cbcd4bda53032af` |
| `core/wiring` | `20f53578935f338e6800e908b0ac1b3b8e83746201bb7ac6f14144d7407730be` |
| `delivery/aggregation` | `ea622ec03fe96d10e73361b1e6a02061f7873be8b139c33e4670c8e09468d619` |
| `delivery/backpressure` | `b862c87803507b88d771b1c726e9b5da202504f6052e4c181177814135c1fc99` |
| `delivery/circuit-breaker` | `20c881bc3b1256e1a1a1d3ec92cb331d971bab10152a54289ac9778382aee7ee` |
| `delivery/data-stream` | `02d29717c19cd324ad00082d91611ecd2638e44ed1bb9d1d69bb69d28bac18ec` |
| `delivery/dead-letter` | `91445388adffeaec5ff36b792718e3c0e3bbf3df1ca173ab3ff62e20e08a0632` |
| `delivery/effect-intent` | `78353460631d9851abe089144242d8cb50936267eda1a02c4597a647a8428ed4` |
| `delivery/idempotency` | `dd6c1c583d7fbd264aa3ac0605fe5ad859b2fab02d13e6454078bbf38b00925c` |
| `delivery/request-reply` | `054d7c4573308cb1d69d4e8b166db6d2ba19ce221034ddd8ad73ac4160ef3a6b` |
| `delivery/retry-timeout` | `6c66629e41b3d2a2d41ca7e96028208e2d95d15076c58c1bd23fa931da9ee2e2` |
| `delivery/routing` | `dec7f970ca07ecc49613ca02d279b11844dedec2c3a8c172c4db60c9920f7473` |
| `delivery/stream-combinators` | `76d4f2c9c2e93ba937e609113ed5e50c565d51e04af0ae71a3ced153bf34b3df` |
| `delivery/time` | `e33c2d5ecc2cd423ace555e804c9dd954cc43a92fe7ff93fe87597125450e540` |
| `delivery/transformation` | `d4413383e9aec94c0dd329434e580b121b45f43175eaa515b0e2523b4103bce9` |
| `delivery/trigger` | `dd6b28e11645d88c26c98c7cf2553c6a7bc241f58c0e9ba2818bdfb8bd5c1b06` |
| `delivery/windowed-idempotency` | `f607b4e7d2c215a48c1223b132f3a46d536d04c753f0b9c4cca8445f805cb7fd` |
| `domain/authorization` | `8363056c8f5f995e3d1cff1f421f488e90797c9ce1f7d28af26ae6b66a3fd971` |
| `integration/ai-batch` | `d2359bd216c7eeac3e884dc7933a9e6e1bc3c0e4df3d8d2eca5122c8f8a90592` |
| `integration/ai-batch-anthropic` | `3d9d482008b009e430720e659258c6380d451b367543e7944bc2d180837bf23a` |
| `integration/ai-embedding` | `d93082245446c75f6f124a696777b60b1903814a64260b1c3c66524b4c51bd72` |
| `integration/ai-embedding-openai` | `bdece85e53bbcf8e50ab11a6cd6599c676bd9b46b12f7da306241ca46ee38c0f` |
| `integration/ai-model` | `f4235a8be041be0d7374311173fccffa186b4bc4aefe1a4c12efd514cf1fa845` |
| `integration/ai-text` | `57a4600864b92a8d8f7a9fa129ef89e102048bc47b46104ba7a32d3bf62cf35a` |
| `integration/ai-text-anthropic` | `695bce0ad91393dd43b21334ae0ac35422f278c577609bd319e49ebdf93e7551` |
| `integration/ai-text-openai` | `b143c5015b388e2475a16e2ea65a228841935ccdff9f93a102c347a9602520b8` |
| `integration/crypto` | `fe4b0e7185f0ea34974e0e47be60c9aab3d1ca49681382241b7b73ad9993157c` |
| `integration/cure-json` | `d123cf62daf7d444e99925dd8cfa38fde840f9d32b49dd720e4e7c901b636941` |
| `integration/http` | `0672cd28ee15b79bfff2682111a5f8ca6fae3440afed226d3e26b23ee24ff0a0` |
| `integration/jobs` | `72a80e3ec12dea175dfc0e5e38f0a6c4b45fc8f94973843b527fd126d7374672` |
| `integration/json` | `911cec4496318fa560769cc72328dc383b30d0f44aac60df27c6274e6c8796f2` |
| `integration/mcp-client` | `95de43b8f09569f5ddf783cfb7873fac922dd02c7decd288b192218d75c355e3` |
| `integration/notification` | `c0cd427253d69dc8bbdca6f66d7e8f2632be57cf9d93e7a5a561ceba634e3c16` |
| `integration/object-store` | `90e91d2f91243ab5eca47d92e7eb26c2885cc320cfa0435629c59c9b0a9385e6` |
| `integration/observability` | `8ae17b97ff389a1e56ca22c44257bb5be24d5e36173f75b8cf471c1830a61bd3` |
| `integration/search-data` | `0e0892c96de67add66f92e6a0bda3d942217d4e2f8d7f8bf9232eea14ed726d8` |
| `integration/secrets` | `5c4ec22114a338537cf26296b83dbedf90d226c7954fd9e87aa06b5e18ab342f` |
| `integration/sql` | `03b15dd1d10ba95a986a5497e05ad40ca267eb3924150d6289ec20d1248c1195` |
| `integration/text-chunking` | `0d43e8babba00d2f17e6c8ecf26f2ffe1f7375258d3fd998f36418e09b1232e7` |
| `runtime/adapter` | `55c68918a2948f40e0abd858101ca74290e1f4d349d048cacdf8cbef00d5dcf2` |
| `runtime/host` | `1fc764e58f63dba6457bc5ec97944eb0e9021c8806abef93308001c9acf6acee` |
| `runtime/os-isolation` | `0210348010874b6295e9752f45deb0ed1fd70e8ada738509f3248d39b1b11c19` |
| `runtime/registry` | `8983854571fc13bcb8213ea71e5842e02779afe0f42d980c12169717198dfd22` |
| `runtime/supervision` | `3ed88dd2f4cf0495b54caa0aa054cee7bfc5fd6f1be0652b9d4870dc6c4af348` |
| `runtime/telemetry` | `897639df67f7eef2f43074d91c7195f6549f1373dbf537126eec732d0048fe6d` |
| `runtime/unit` | `464ec731a559a7aa5a8c4409a2d514b9c7830a52de9f029af3c22809db191c24` |
| `state/artifact` | `00ec448b890797bca53606a8437f619e35f6d74ce9403b22e6d8129e1a6b62b0` |
| `state/audit-log` | `839c402b1eac01713466bf83512dda59b58e63127ec33c6b30949bfe8b0dc179` |
| `state/checkpoint` | `56ef1ba1ccc61f403269110b9270980e93a15ef4ba9b47ef33b8b929796a3c9e` |
| `state/event-log` | `d367b3ff5f7b45b699a523a36e009a0a081156134e8c2107e1146668b75b03de` |
| `state/lease` | `3a454246403b435a70b381760f55759f380b833a8d901c69c14205c85071b7ff` |
| `state/outbox` | `ddff017e71185061ed59c54d8331392a1378dd679aa05667673e99297fa48c0b` |
| `state/scheduler` | `d4da7ad1fc4a9d8b4d58f3ae6b4e76035fbb10e392033b3e12479438ccdfc794` |
| `workflow/approval` | `fb4eca7cc00c381beb2f9e70f43146f13db0f4c9846c62d9976a61e8ab8704c9` |
| `workflow/budget` | `bf176c03da60e538ad0a110694aca703706fc5b1c8ccd83194cde4c7da4c819a` |
| `workflow/context-selection` | `81007ed4b12f6437e3ffa67f161f6401741aaf023b28d2db98454f5c43d74369` |
| `workflow/dependency-graph` | `5f1c93429ac75b7d09f28ef280c6ef5b3ef9f33a23be5d53ec2bc8cacc2130ba` |
| `workflow/run` | `52666906d97cc5a6a2f04ef753bed8b6c221d14fd873b3b2c45ee88d0684050c` |
| `workflow/state-machine` | `2ca7d65169b9f94af253fdbf718ed46134fda5760ee7bb49717069969da1b83c` |

#### V1B ready rows

| Piece | `manifest_sha256` |
| --- | --- |
| `assembly/checked-command` | `6c8f5dd71f2c476134ed54c341d3499e33f2f9b912ee1d1129a689ac6cad4fb2` |
| `assembly/knowledge-ingest` | `6d2ad553a51dffba4a54c2eca0cb0daeae241ea50a9368aa883413a06d442988` |
| `assembly/run-engine` | `6376b6f4317e7d9fad3a2f11968735d0a4b2a77e57072106acc276a539dd94c7` (exception to F's base: updated by ELZ-408) |
| `core/payload-schema` | `b7f5c1abbf1e90c7c3190127d715827731949fb1ccdf721117513fa4189b9935` |
| `delivery/dead-letter-store` | `d7f2ddd3af34d072a607afd88c7c3d741f3bc1f82fde1c89091a3e30324a0e47` |
| `delivery/debounce` | `7a63e94eda0d9c28ddbdcec2aebb06c5d5ffaa698a0a2b7d8e92997dd25a9ce6` |
| `delivery/durable-mailbox` | `5376ff753aea2d245d2cc88784e3a82c0d1ab511c7ba65f056de62dd78ce3486` |
| `delivery/model-routing` | `6f71175ad481d87de360f6f59cc65f940b14f793eeacadee73b388885069165d` |
| `delivery/provider-stream` | `b1aba6620815b0e185cc7294c02f8fc0b4bffaf44ab1c511446a76c89c1e22f7` |
| `delivery/rate-limit` | `535d57a252292c6e600d4f08d2da6b842be068d708ab082cfbcd9d5c6e3a0e7b` |
| `delivery/room` | `f868b250d700e1ee52a8bdfacf85cf1071fa26b29a20edf59a3f1c0265bef354` |
| `domain/entitlement` | `391d5b25f5fffcce928ab879128848bc81aedff3b8f3d66d8178d485060258db` |
| `domain/kill-switch` | `971613eddc65847123cecf183492f6dee11a0d037a99b45e969ac78a2c498182` |
| `domain/membership` | `3a183a7107177b6dd6d7848940bc576002879ce8aab6fa6b114630882781ab96` |
| `domain/metering` | `6c0b954f5dbfcb8ffffe7879d99aec1cf27562eca2af67149066f77b9c9dd7f8` |
| `domain/principal` | `b3468d849382ec5505a07a5a042bcad59ba82cd0df4e0d172735ba777fd5037d` |
| `domain/provider-data-policy` | `03fd58fa003576bd19f7f6b5077043e8e32818454afa1c40d9a296f063d09ba8` |
| `domain/quota` | `3492eece0ca64c43b3858ba95ee66c22919041f6edec7e647f1c93ae15cf5639` |
| `domain/recipe-config` | `fb61ce4dccb71d917bbb67c914d1e6097eb29096dc78b15cbfd9a714c2a5d5d7` |
| `domain/recipe-graph` | `5a5f72e33a16d79851c73d7322935db9d36f45ad2f27e3dc171db8b4fc1a444c` |
| `domain/recipe-package` | `1c026244dbc854ce6cfedf4912156a6a2437e998b84d2ba926a42357d881347e` |
| `domain/trigger-binding` | `43aae395c28a1bd68df6b07942ecec8376be1e669b38b7b7525356463d5e76a9` |
| `integration/ai-text-compatible` | `7268da161057601b914003f9653d890b764c789e22e1c55bbb61b43db461599a` |
| `integration/ai-text-google` | `80f5bd66ad479152472a3f7214a2973f94dc8469194459f4fadb85386dfa86f4` |
| `integration/ai-token-count` | `403b2ce627c2391e343e381940cb30270c7b180954fddddacaa01693008cc2e5` |
| `integration/document-parse` | `1cf2a40804f1bf4d26327a12ab6b6c0d11ced182346cc5194d5b44384a3a18c1` |
| `integration/egress-policy` | `b85f823dc074eadb28ebfb5919378e66ae489a40bf8057db8444c85c85ad30d8` |
| `integration/encryption` | `da6965a659a64d96d2cdacfbeed3a978151f1db2162339f7022dbc4a78b77938` |
| `integration/mcp-multi` | `3bfb14e162cecb26cbdae82ab4de7a13815264973899e40d50c4f193317b9021` |
| `integration/mcp-runtime` | `cd31e3e48d59a15233d3ffa54776496521c207aade9f896d17de9ba28857ab5b` |
| `integration/mcp-server` | `a66dc6f56ea485075a86c42233d6d1d229f0cc6fcac3d692f78fef472cfc2e9d` |
| `integration/oauth-client` | `b96144cdf6bde25b5c41f8e11f8288d95f899922ac1bad72041d6b3421d6ed3c` |
| `integration/pii-redaction` | `3cd1269062b2644f400a02eac05fd78eb35ffb3e51399bcdaab8c85e0a08ec6d` |
| `integration/token-verify` | `e24fb71dd6e866bccee63ab61a5f13cbce4302f6a586276d5afef85355f792c6` |
| `integration/webhook-in` | `44541c299f5679d119e12936728eae83138e65c13dd38050b3a087e5f26c9435` |
| `integration/webhook-out` | `f6e1905851e72056a1ee9cf47ea88c47d196f048818748357721eea3f54b39f8` |
| `runtime/async-work` | `e11814bc9ba18d1797829c35f00e4e83b38a7186e9ef3bd01b3d9a45098ff7c1` |
| `runtime/durable-unit` | `7cef42ef2a81da3b0861f6b580ca29e39277cdf9ca85f62a5c06e1ed0f6067a4` |
| `runtime/dynamic-units` | `11563fa0963b44ce683067832166f53ea978d1d9b0cef0436b7e700cd5bb3396` |
| `runtime/lua-binding` | `35c56e342267608a01daa256248ceefaaf237e47bd85ffbedcf37e1b83822ec1` |
| `runtime/lua-sandbox` | `8510645210894125c39fb3362538a890f43cd99211c900713cc8a62b471d92e0` |
| `runtime/recipe-test` | `ac09b18c686fea12eec388189c4544440e7b5dbd921489eae894e0998aaf2530` |
| `state/conversation` | `363f0bcb1587d10de1ad7c87b46991b2910cdb7129f1ec2e4e6f0bd3839470ab` |
| `state/memory-record` | `84022887d01685bafdcf0f0c4319503c3c30abb448043cf4cb0c829c48ed551b` |
| `state/recipe-store` | `3a7e013944b3cda007bc518f0bd9ea197bd91832293563ca117cac8ce20f1b30` |
| `state/retention-erasure` | `176e7287a9373709abac01b19723dd2eae499f1881d97645e0950feccb05bd96` |
| `state/tenant-isolation` | `ff22e8b60ebf7e3fb4f9e287bd88895a006c38358d055fd7cf56414bd741ac9f` |
| `workflow/agent-loop` | `06b7485c568b8841f1482c59e367e38e07feb4e0b75e4eac2cd8f3c00cccfbb8` |
| `workflow/bot-run-lifecycle` | `fb366e989508a675369f3943ebe9d8d546e48c3c194ee848a1cda49060bcdf9d` |
| `workflow/citation` | `492264c31654fd1d9d15f67ce65e8fb7e9f5263cf3c4f4cff317a7bbf896577c` |
| `workflow/context-compaction` | `9f30bca92525b5cf2a91c65aa2bd143e1e36365b24da2deafe5fa83bee499a5f` |
| `workflow/delegation` | `8632ecc3f8b9bb298a986df1872c81f025c0301f9c2d05a8bc556d2306187a32` |
| `workflow/eval` | `d3bd3d29546e272f5310f4d022adde2bd0eb03a0fb4d5bd8e496b64f9a361717` |
| `workflow/graph-run` | `b4e5bff41c81503cdf539e94e6349f243bffcf0095d1fafb2315dd2fe69f4f49` |
| `workflow/lua-tool` | `66200c218a39f2f2568965202e09d7ee9a9f3e609ca9f82d4737fe66f64ffd43` |
| `workflow/mid-run-input` | `e077775a1ec59fe57b6d00d5110afe9ff63318c22f83914cc9a04f76451e6766` |
| `workflow/node-outcome` | `d652f40a7fe97d9255bd4573ff9aecf8cf206eaa990e072a75d246258c26f830` |
| `workflow/output-repair` | `1f6401bf7bed26cad13ec1f36f18fd340d5074e720d23ef1688fe3c93c375669` |
| `workflow/pattern-step` | `8e0f5d8ffc864a696f8e31e20f18be45f6ef403e090d60672c9d6c4a9605554b` |
| `workflow/prompt-assembly` | `9dcfa2a28861ea1512b0fd76156ff12e975011f59f65566cd0b95a89bf98e29b` |
| `workflow/recipe-check` | `9ae4255f3a6c0180086b465672c325577e34e16e37c1f447ae2e31e84ff16fee` |
| `workflow/run-approval-release` | `737e954103bd21d87e573cb730287fd193d550d51a7b6c7a294e944bb04a9c30` |
| `workflow/run-resource` | `9a97218a45a9c00e575a963fe55e2b21fdbf0880bb5219c0b8076a86450c0e47` |
| `workflow/runtime-graph` | `f6183749a90d7e669f4c15e2569c3b493ac02625a99a244b17bca42c1973b315` |
| `workflow/skill` | `d6df0640abb580ef906d6e579a0245fb2f0fab1cf0f88ccf752f84faafa02e09` |
| `workflow/stall-detect` | `1bd277dddfd9343f01e478c033521469eff270aca34b24c1914f3b2d4de73bf1` |
| `workflow/tenant-lifecycle` | `3034eb384be1e6f3d5b5c11e7c845976e88dbceb0daa90416a9c221cc8c8fac5` |
| `workflow/tool-registry` | `fdc6675fe8a127721f4982a28810438d0f0543ab4e19ae07e2bd3b43b3b983f2` |
| `workflow/tool-result-limit` | `97fa7667eb20590f373a3e1fd0a95c2e829050c8e7101206e0bd6980253ae6c0` |
| `workflow/turn-policy` | `2e456abb5bbcf79bfb909b6d020f6809eb121825e7a543cc42de107752676201` |
| `workflow/typed-decision` | `27e9e653d7393007bff6b3bdfe2c12b2b0a7f8fc73a23686e7837a19aae54cd4` |
| `workflow/untrusted-content` | `a6195ec2ef48341789f1980500cb7629f9ae928b3cbea279beeede3265eb8f62` |
| `workflow/version-pin` | `f3a7ad8ad832bc5e2ebbe544fa64bf407702f11fbb662702e44b7ee80750d7bc` |
| `workflow/wait-for-person` | `74a007107decca7d430ad096a2a20341b10bd786c7a1689e6cc3a45762b4b080` |
| `workflow/work-item` | `9ed85d7e47fa61d73e41fd006387bc58f4774f3d62efb1c94f5c08206e19b207` |

#### V2 ready rows

| Piece | `manifest_sha256` |
| --- | --- |
| `assembly/ledger-checkout` | `cf0cada0446639db2a835bb3c9f2a5a32bed8abe3a51fad38e79c9af1cf64b4e` |
| `domain/invoice` | `6461ee16203a7675984a8a4da092e3e6a0f835b033d0b8c545467aa99ad57504` |
| `domain/journal` | `2f3a1ce9c6acaf50e31b8b593c656fe268ad0b0d2b2ef1e0eecd42f40600a0ba` |
| `domain/money` | `2b7bf31dd597a1124340bb9f81c29bc89875686658161fbd257f02074104ebdc` |
| `domain/payment-lifecycle` | `b8b8988dd435acf6d442ff9ddf9a01a5af1bdee4d1b05ba67e033be85d98feaf` |
| `domain/plan` | `3f2b15858bf07ff4db161892cf69dae142e6140d09cbd24b03e26b9ae820f17d` |
| `domain/pricing` | `c2da47be8e86eb4c7375652ff944cb125b23e8cf3d221c7a7422016be9f1f2ec` |

**One release, so the cross-release closure is accepted with it.** `integration/search-data` (V1) copies `state/tenant-isolation` (V1B) into every consumer. V1-ACCEPT therefore holds only together with V1B-ACCEPT. A second reason: V1 Pieces carry in-place changes made by V1B jobs, among them ELZ-305 (`runtime/os-isolation`) and ELZ-382 (`integration/mcp-client`), so the frozen V1 code is not the V1 jobs' code alone. Because the first release passes the three gates together, nothing moves. The acceptance report states this. The job's release stays V1, and the job dependencies keep their order.

### What each still-unpublished RC job and each non-ready row becomes

Every non-ready row formerly selected either moves to `later` or is accepted as an index resolution. No RC job is kept and built for this release: under decision 1 the release waits for no deferred row. The prerequisite builds were ELZ-387, the Level 1 repairs and the two admitted repairs ELZ-401 and ELZ-402. No row is dropped from the catalogue, because the 97 baseline rows must stay and `check-roadmap.py` refuses a lost one. A `later` row stays in the inventory with its disposition.

| Job | Release | Row or gap | Decision | Reason |
| --- | --- | --- | --- | --- |
| RC-02, RC-03, RC-05, RC-07, RC-08, RC-10, RC-11, RC-12, RC-13, RC-15, RC-16, RC-18, RC-19 | V1 | none left | **Accepted as resolved** by the published successor that its status names (ELZ-097, ELZ-106 and ELZ-107, ELZ-105, ELZ-269 and ELZ-300, ELZ-303, ELZ-055, ELZ-347, ELZ-116, ELZ-096, ELZ-098, ELZ-079, ELZ-082, ELZ-054) | The output moved to a merged task with a ready manifest. The old dependencies of RC-07 on RC-06 and of RC-19 on RC-43 are history and select nothing. |
| RC-14 | V1 | none left | **Accepted as resolved** by ELZ-101 (`delivery/data-stream`) | The broader transfer gaps are not a row. They stay a kept-open option. |
| RC-26 | V1 | none left | **Accepted as resolved** by ELZ-100 | "Resolved planning index". No bulkhead task was admitted. |
| RC-32 | V1 | `domain/value-types`, `domain/saas-controls` | **Accepted as index resolution** | "Discoverability indexes only" (ELZ-033). No executable output. |
| ELZ-033 | V1 | `core/grounding` | **Accepted as index resolution** | An evidence index, not an executable Piece. It is checked by `check-roadmap.py` and `check-claims.py`. |
| RC-01 | V1 | `state/schema-evolution` | **Later** | Its blocker asks for "first real evolution need; no placeholder v2". The release freezes formats with fixtures instead. After the release, a format change is a new ID with its own reader. |
| RC-04 | V1 | `runtime/faces` | **Later** | Each Piece already declares its Telemetry, Config and Control in `piece.json` ([operational contracts](../operational-contracts.md)). No caller needs one shared operational interface. Wave 6 deferred it as well. |
| RC-06 | V1 | `integration/identity` | **Later** | Owner, 2026-11-20: no identity provider in core, and OIDC or passkey login stays a consumer recipe. `domain/principal` (ELZ-267) and `integration/token-verify` (ELZ-268) are ready. |
| RC-09 | V1 | `integration/auth-policy` | **Later** | No product names an outside authorization provider. `domain/authorization` is ready. |
| RC-17 | V1 | `integration/agent-runner` | **Later** | Demand-led (catalogue: `disposition` `defer`, `phase` `demand-led`). `workflow/agent-loop` serves the in-process agent. |
| RC-42 | V1 | gap `delivery/durable-idempotency` | **Later** | "Unresolved". No caller asks for durable operation deduplication beyond what `assembly/checked-command`, `delivery/effect-intent` and `delivery/idempotency` give. A composition review can resolve it after the release without a new ID for any ready Contract. |
| RC-43 | V1 | gap `delivery/outbox-dispatch` | **Later** | ELZ-104 left a residual handoff "open for separate admission". No new dispatcher is authorized. |
| RC-44 to RC-70 | V1B | none left | **Accepted as resolved** by their published successors (the RC-50 row says "admitted as ELZ-127"; RC-60 to RC-67 have all portions published) | Each output has moved to a merged task. |
| RC-21, RC-22, RC-23, RC-25 | V2 | none left | **Accepted as resolved** by ELZ-299, ELZ-297, ELZ-304 and ELZ-369 | The outputs moved. |
| RC-24 | V2 | `integration/payments` | **Later** | Decision 1: no payment provider is chosen. Wave 9 Q9 D built the provider-neutral `domain/payment-lifecycle` (ELZ-365) and `assembly/ledger-checkout` (ELZ-378). The provider comes as a new Piece behind payment-lifecycle's provider Need. |
| RC-20 | V2 | `domain/policy-rules` | **Later** | "A product must provide a finite rule schema … before choosing an evaluator". No product has. |
| RC-27 | V2 | `delivery/pubsub`, `integration/message-broker` | **Later** | P11 names no broker. These rows come as new Pieces when one is chosen. |
| RC-28 | V2 | `delivery/resequence` | **Later** | Wave 9 found no caller. Provider events are ordered by the payment state machine. |
| RC-29 | V2 | `workflow/build-graph` | **Later** | "Product-specific". No product needs it. |
| RC-30 | V2 | `integration/sdk` | **Later** | "Build only for an actual cross-process assembly". MCP (`integration/mcp-server`) is the door today. |
| RC-31 | V2 | `ui/component` | **Later** | Demand-led. The consumer owns its screens. |

Unchanged and outside the gates: RC-37 to RC-41 (`examples-later`; RC-41's output moved to ELZ-378) and RC-33 to RC-36 (`research`, V3). The Wave 4 to Wave 9 deferred handles that have no row (the channel adapters, `workflow/client-tool`, the a2a Pieces and the others listed in "What remains after Wave 9") are not jobs. Decision 1 covers them: each comes later as a new Piece.

**What each product loses to `later`.** The products keep their job lists, so a product job in `later` is a part that the first release does not supply:

- P01 (background reports and imports) and P08 (artifact upload and transformation): RC-42.
- P02 (webhook and API-driven work): RC-42 and RC-43.
- P04 (tenant invitation and feature access): RC-06, RC-09 and RC-42.
- P07 (bounded agent delegation with review): RC-17.
- P10 (internal transfers and reconciled refunds): RC-24, RC-42 and RC-43.
- P11 (event-driven and incremental build workflows): all four of its jobs (RC-27 to RC-30), so the first release supplies no part of P11.
- P03, P05, P06, P09 and P13: none.

For RC-42, the reason above holds for each of its five products: the only jobs that depend on it are the `examples-later` jobs RC-38 to RC-41, and no job in stage `pieces` waits for it. The only frozen jobs that name a moved job as a dependency are RC-07 (on RC-06) and RC-19 (on RC-43), both already resolved, and the moved jobs that depend on each other (RC-09 on RC-06, RC-30 on RC-17, RC-42 on RC-01) move together. A product claim for P11 waits for a next release, which F records in that product's `limit`.

**The published jobs.** The acceptance (A) records, for each published job, its closed issue, its merging pull request with the merge commit, and the ready manifest of each output at the frozen commit. This includes the 20 "historical-closed" V1 rows, which predate the current review records. The acceptance does not redo their tasks. It records the evidence that each one has:

- A job with outputs (ELZ-002 to 009 and ELZ-013) is accepted by its ready outputs at the frozen commit and by the full check on the frozen code.
- A job with no output (ELZ-001, ELZ-014 to 021, ELZ-025 and ELZ-032) is a harness, document, evaluation or CI job. It is accepted by its closed issue, by the commit where its task's named work landed, and by the check that carries it today, where one exists.
- ELZ-001 has no merging pull request. Its evidence is the bootstrap commits `3965fb26` ("Bootstrap Elzoo with pinned Cure …") and `49a0a532` ("Record bootstrap acceptance …"), and the pinned `mix check` itself, which runs on the pins it set.

A job for which A finds none of this is listed in the report as undecided evidence for the coordinator, and A sets no gate to accepted while any such job is undecided. The gate wording allows an "exact tested upstream/index resolution reviewed", and that review decides it. The task does not guess the job accepted. F corrects ELZ-028's status to the form of the other early rows.

## What "the release" is

The plan uses only what [consuming.md](../consuming.md), the [coordinator guide](../development/13-coordinator.md) and the export code already support:

- **The release commit.** The merge commit of the release-mark task M, accepted only when the `symbolic-check.yml` push run for that exact SHA on `main` is green (Q1 A). M changes no Piece, so its Pieces are byte for byte those of the last fixture task's merge, which the acceptance and the fixtures checked. A receipt's `revision` names the commit taken. No marker branch is made.
- **Taking it later.** M's consuming.md section names M's pull request, because a commit cannot name its own SHA. It tells consumers to find that pull request's merge SHA on GitHub and confirm that its own `symbolic-check.yml` push run on `main` succeeded before using it as the first release. If that push run is not green, the release mark is not accepted: a later green repair commit does not qualify, even if it carries the same mark. To take the accepted first release, run `mix elzoo.take` from a checkout of M's merge SHA. The usual latest-green rule in consuming.md lines 34–35 gives the newest code instead; it does not attest release acceptance. An export from the accepted release commit copies the consuming.md section that M wrote.
- **Its record.** The release-mark task M names the release, which is M's own merge commit. The documents name it by M's pull request; release-plan.json names it by M's task ID, because `AGENTS.md` section 3 keeps pull request numbers out of that file. Level 5 lists every place; the main ones are:
  - in consuming.md, a short section "The first release" (the pull request, the exact merge SHA's green push requirement, and the new Piece ID and migration-note rule from the accepted release commit, lines 162–169);
  - in the two bullets of `AGENTS.md` section 4 ("Elzoo is not released yet …" and "From the first release …");
  - in docs/choices.md, "In-place change before the first release";
  - in the `status` of the three gates in release-plan.json (by M's task ID, not a pull request number).

  The coordinator guide lets `AGENTS.md` change "only when the owner asks". The owner's answer to Q2 is that ask.
- **No version change.** `version: "0.1.0"` in `mix.exs` is the harness project's version. No receipt or consumer reads it. Changing it would touch a shared path, run the full check and give a consumer nothing. The release is named "the first release", and its commit identifies it.
- **No changelog file.** Everything in the first release is new. LEDGER.md at the release commit lists its Pieces, with each README's Contract, limits and grounding. After the release commit, each changed Contract is a new ID with migration notes, which the LEDGER and release-plan.json record.
- **No tag and no GitHub release.** The owner chose the documents-only mark (Q2 A).

## Open repairs and observations

**Rule of the cut.** Before the freeze, a change lands if it does any of the following:

- changes a ready Contract that should hold from the release (after the release commit, such a change needs a new ID, and for a foundation Piece every dependent would have to opt in);
- changes a record format of the three fixture Pieces;
- leaves a Contract claim of the frozen set without evidence;
- or comes from an owed review whose findings may change a Contract.

Everything else waits unless the coordinator explicitly admits it before the freeze, as with ELZ-401 and ELZ-402. That covers unrelated timing flakes, which fall under the rerun rule of `AGENTS.md` section 5, other repairs that only restore a Contract (they keep the ID after the release too), and process or CI text that no Piece reads.

| Item | State at F's base | Decision | Reason |
| --- | --- | --- | --- |
| [#930](https://github.com/balungpisah/elzoo/issues/930) | ELZ-387, [#945](https://github.com/balungpisah/elzoo/pull/945), `3e72f6f9` | Landed (Level 0) | Decision 2. It adds a control key to the run-engine record, so it precedes the format freeze. |
| [#821](https://github.com/balungpisah/elzoo/issues/821) | Merged as ELZ-358 (PR [#864](https://github.com/balungpisah/elzoo/pull/864), `10dfd080`); the issue is closed as completed | Landed | — |
| [#843](https://github.com/balungpisah/elzoo/issues/843) | Merged as ELZ-359 (PR [#863](https://github.com/balungpisah/elzoo/pull/863), `9580f2b1`); the issue is closed as completed | Landed | — |
| [#931](https://github.com/balungpisah/elzoo/issues/931), [#932](https://github.com/balungpisah/elzoo/issues/932) | Merged as ELZ-385 (PR #940) and ELZ-386 (PR #939); both issues are closed | Landed | — |
| [#852](https://github.com/balungpisah/elzoo/issues/852) | ELZ-389, [#968](https://github.com/balungpisah/elzoo/pull/968), `a75f381c` | Landed (1a) | Fencing recovery is on the durable path pinned by X2. |
| [#834](https://github.com/balungpisah/elzoo/issues/834) | ELZ-390, [#962](https://github.com/balungpisah/elzoo/pull/962), `7f1b126e` | Landed (1b) | Settles the stop set of `delivery/room`'s repeated `open/3` Need and the manifest hash. |
| [#710](https://github.com/balungpisah/elzoo/issues/710) | ELZ-391, [#964](https://github.com/balungpisah/elzoo/pull/964), `d4cec899` | Landed (1c) | Restores the one-result guarantee of `runtime/os-isolation`. |
| [#918](https://github.com/balungpisah/elzoo/issues/918) | ELZ-392, [#963](https://github.com/balungpisah/elzoo/pull/963), `9cc78fac` | Landed (1d) | Supplies the missing recipient case and host-duty grounding. |
| [#886](https://github.com/balungpisah/elzoo/issues/886) | ELZ-393, [#971](https://github.com/balungpisah/elzoo/pull/971), `10701c48`; ELZ-400, [#977](https://github.com/balungpisah/elzoo/pull/977), `f0fb4d95` | Landed (1e, 1f; Q3 A) | Bounds OAuth refresh using a new explicit transaction timeout in `state/tenant-isolation`. |
| [#915](https://github.com/balungpisah/elzoo/issues/915) | ELZ-394, [#965](https://github.com/balungpisah/elzoo/pull/965), `71086455` | Landed (1g; Q3 A) | Bounds `delivery/model-routing`'s `tried` input. |
| [#885](https://github.com/balungpisah/elzoo/issues/885), [#884](https://github.com/balungpisah/elzoo/issues/884) | ELZ-399, [#970](https://github.com/balungpisah/elzoo/pull/970), `9f650d2c`; ELZ-395, [#973](https://github.com/balungpisah/elzoo/pull/973), `9103cd79` | Landed (1l, 1h; Q3 A) | Exercises composition and settles overlap and grant identity for `domain/plan`. |
| [#701](https://github.com/balungpisah/elzoo/issues/701) | ELZ-398, [#972](https://github.com/balungpisah/elzoo/pull/972), `829eda6a` | Landed (1i; Q3 A) | Gives `delivery/dead-letter-store` an opt-in generation check on resolve. |
| [#946](https://github.com/balungpisah/elzoo/issues/946) | ELZ-396, [#974](https://github.com/balungpisah/elzoo/pull/974), `5bb57c13` | Landed (1j) | A refused reused action ID no longer removes the live occurrence's lifecycle wait. |
| [#947](https://github.com/balungpisah/elzoo/issues/947) | ELZ-397, [#966](https://github.com/balungpisah/elzoo/pull/966), `ce2adb70` | Landed (1k, before 1i) | A purge retry after an unknown outcome can remove another batch; the Contract now says so. |
| [#969](https://github.com/balungpisah/elzoo/issues/969) | ELZ-401 ([#975](https://github.com/balungpisah/elzoo/issues/975)), [#979](https://github.com/balungpisah/elzoo/pull/979), `edd27760` | Landed (coordinator admission; V1B `pieces`) | Retries the transient CI MinIO bucket check after readiness. |
| [#967](https://github.com/balungpisah/elzoo/issues/967) | ELZ-402 ([#976](https://github.com/balungpisah/elzoo/issues/976)), [#978](https://github.com/balungpisah/elzoo/pull/978), `288149cd` | Landed (coordinator admission; V1B `pieces`) | Repairs the test-only run-engine busy-stop interleaving. |
| [#912](https://github.com/balungpisah/elzoo/issues/912) | Open. ELZ-382 ([#928](https://github.com/balungpisah/elzoo/pull/928)) states and tests the bound of 64 distinct tokens per session. | **Can wait** | The shipped claim is exact and tested. A signal before the bound or an eviction that keeps redaction is new behaviour. Q3 A did not select it. |
| [#670](https://github.com/balungpisah/elzoo/issues/670), [#669](https://github.com/balungpisah/elzoo/issues/669), [#547](https://github.com/balungpisah/elzoo/issues/547) | Open timing flakes under host load | **Can wait** | The rerun rule applies, and #670 stays unchanged by the owner's decision ([choices](../choices.md#a-flaky-elz-176-bounded_time-test-stays-unchanged-2026-11-21)). The sandbox has no default limits (`runtime/lua-sandbox` README line 79, `wall_ms` at most 1,000), and `workflow/lua-tool` requires all five (its README line 29). So A's Lua entry states `wall_ms` 1,000, twice #547's 500 ms, and X3's Lua spec does the same. |
| [#715](https://github.com/balungpisah/elzoo/issues/715) | Open. Notes on the recheck steps of the coordinator guide. | **Can wait** | Process text. No Piece or gate reads it. |
| [#890](https://github.com/balungpisah/elzoo/issues/890) | Open. Hosted-runner apt source. The full rerun passed. | **Can wait** | CI provisioning, not the frozen code. A failure gets the rerun rule. |
| [#98](https://github.com/balungpisah/elzoo/issues/98), [#76](https://github.com/balungpisah/elzoo/issues/76), [#70](https://github.com/balungpisah/elzoo/issues/70) | Open: the CI tracking issue, the deprioritized CI guard, and the ARM64 lane that `AGENTS.md` section 3 now forbids | **Can wait** | Not part of the release. #70 is still the owner's decision: close it, or rescope it to a GitHub-hosted runner. |

### Pre-freeze rechecks (2026-11-25)

- [`domain/journal`, #698](https://github.com/balungpisah/elzoo/pull/698#issuecomment-7153390498): no findings.
- [`domain/metering`, #696](https://github.com/balungpisah/elzoo/pull/696#issuecomment-7153375303): no findings.
- [`delivery/dead-letter-store`, #699](https://github.com/balungpisah/elzoo/pull/699#issuecomment-7153399794): one BLOCKER, tracked as #947 and published as ELZ-397. #701 was confirmed, not a new finding.
- [Skipped automated review, #798](https://github.com/balungpisah/elzoo/pull/798#issuecomment-7153393924): no findings in the other-family recheck of `06e50161..fa99ba68` and its non-empty remerge diff. The automated replay stopped before any push because the remerge patch did not apply at `docs/plans/views.md:579`. The posted fallback record permits removing the skip-list row.

## Rules of the freeze

These rules hold from the merge of ELZ-403 (F) to the release commit. F's merge `0a76dd21` set the original baseline and still defines the frozen job set. A accepts the frozen set before the fixture tasks and release mark; the new-ID rule starts at the release commit, not at F.

1. Only these merge: the release tasks; repairs that restore a ready Contract; and test-only Piece repairs (`AGENTS.md` section 1). A repair published during the freeze takes stage `release`, so the derived frozen set does not change after F, and A lists it with its commit. A change to a ready Contract, a new ready Piece or a new job in stage `pieces` of V1, V1B or V2 waits until after the release commit. New Piece tasks for deferred rows may be published and built meanwhile with stage `later`, but they merge after the release commit.
2. The record-writing paths of `assembly/run-engine`, `workflow/pattern-step`, `runtime/durable-unit` and `runtime/recipe-test` do not change. If a repair needs them to change, the release stops, and the owner decides whether to freeze again. For X1–X3, the owner chose option A on [#990](https://github.com/balungpisah/elzoo/issues/990) and moved the baseline to the ELZ-408 merge `71e5f2b9` because the cold-VM recovery fix changed a record-writing path; ELZ-409 is an admitted test-only repair and does not move that baseline.
3. A defect that A finds is its own repair task. One that restores the Contract merges during the freeze subject to rule 2, and A records it with its commit. One that needs a Contract change stops the release for the owner.
4. The review, exact-head check, queue and red-`main` rules are unchanged.

## Dependency levels

Each task names its new external dependency, which is "none" throughout. No provider task, pin change, PostgreSQL extension or CI service is added.

### Level 0 — landed

- **ELZ-387** (`assembly/run-engine`, `messages: :while_active`, V1B). Merged as [#945](https://github.com/balungpisah/elzoo/pull/945) at `3e72f6f9`.

### Level 1 publication — work that must land before the freeze

One publication records both pre-freeze build tiers. The labels 1a–1l identify items in this publication, not build levels. Run disjoint lanes in parallel; a Tier 2 task can start as soon as its own dependencies are merged, without waiting for the rest of Tier 1.

| Pre-freeze build tier | Tasks in this publication |
| --- | --- |
| Tier 1 — no dependency on another task in this publication | 1a (ELZ-389), 1b (ELZ-390), 1c (ELZ-391), 1d (ELZ-392), 1e (ELZ-393), 1g (ELZ-394), 1k (ELZ-397), 1l (ELZ-399) |
| Tier 2 — depends on a Tier 1 task | 1f (ELZ-400) after 1e; 1h (ELZ-395) after 1l; 1i (ELZ-398) after 1k; 1j (ELZ-396) after 1a |

**1a. [ELZ-389](../../tasks/ELZ-389-run-engine-fencing-recovery.md), `assembly/run-engine`, #852: diagnose and repair the recovery flake.**
- *Dependencies:* ELZ-127, ELZ-385, ELZ-387 (same directory, so it starts after ELZ-387 merges). *Release:* V1B. *New external dependency:* none.
- *Contract sketch:* unchanged. The task names the cause. If the test itself races, it makes a test-only repair. If the engine's fencing recovery is at fault, the fix restores the README's recovery Contract. If the fix would change a record or a control key, the task stops and says so on the issue, because that is a Contract decision before the freeze.
- *Acceptance:* the test "unpaired original input resumes from stored time and facts after owner-tree fencing", located by its current line on the build base, fails under `mix test <file>:<line> --repeat-until-failure 200` on the base (record the count) and passes after the repair. Every run-engine test passes. Negative control: restore the fault in the worktree, and the repeat fails again. Durable state and unknown outcomes: local small gate and full review.
- *Kept open:* nothing new.

**1b. [ELZ-390](../../tasks/ELZ-390-room-open-stop-set.md), `delivery/room`, #834: name the stop set of the repeated `open/3` Need.**
- *Dependencies:* ELZ-348. *Release:* V1B. *New external dependency:* none.
- *Contract:* text only. The README and matching `piece.json` Need say that the host repeats `open/3` until `{:ok, _}`, until `{:error, {:mailbox, :conflict}}` (returned only once the conflict release has finished), or until a definite step 1 or step 3 refusal. No code change.
- *Acceptance:* the existing case 2 of the room tests is named as the grounding. Every room test passes. `delivery/room` is a durable Assembly (tasks/ELZ-348-room.md), so even a text change keeps the local small gate and the full review.
- *Kept open:* nothing new.

**1c. [ELZ-391](../../tasks/ELZ-391-os-isolation-recovery-notification.md), `runtime/os-isolation`, #710: one result per run across an Adapter restart.**
- *Dependencies:* ELZ-029, ELZ-305. *Release:* V1B, because ELZ-305 is V1B. *New external dependency:* none.
- *Contract sketch:* this restores "does not notify twice". The fix makes the decision between a dead Owner and a retired row in `recover/1` on one consistent read, so an Owner that retired its row as finished after the snapshot gets no observer. No new option and no new result.
- *Acceptance:* a deterministic interleaving case in which an Owner retires between the snapshot and the liveness check: one original result only (`completed` or `unknown/port_closed`, according to the fixture). The case uses a test-only hook or forced order, not a sleep. Negative control: restore the old order, and the original result is followed by a spurious `unknown/owner_exit`. Native code and concurrency: local small gate and full review.
- *Kept open:* nothing new.

**1d. [ELZ-392](../../tasks/ELZ-392-ledger-checkout-recipient-evidence.md), `assembly/ledger-checkout`, #918: the recipient case, the grounding line and the wrap.**
- *Dependencies:* ELZ-378. *Release:* V2. *New external dependency:* none.
- *Contract sketch:* unchanged. One scenario: an existing payment of the approved terms with another recipient is refused like another amount. The `piece.json` assumption gains the README's host duty for the allowance Needs. A README wrap.
- *Acceptance:* the new scenario passes. Negative control: compare the amount only in `same_terms?/2`, and the recipient case fails. Durable state and money: local small gate and the full review, as ELZ-378 had.
- *Kept open:* nothing new.

**1e. [ELZ-393](../../tasks/ELZ-393-tenant-isolation-transaction-timeout.md), `state/tenant-isolation`, #886: an optional Repo transaction timeout.**
- *Dependencies:* ELZ-270. *Release:* V1B. *New external dependency:* none.
- *Contract:* the new `transact/4` accepts an explicit Repo transaction timeout of 1..600,000 ms. It refuses invalid options and, on the explicit path only, an existing Repo checkout before I/O. A deadline failure returns `:unavailable`. `transact/3` and `[]` keep existing behavior; there is no per-statement timeout.
- *Acceptance:* a short timeout prevents the held test transaction from committing; a longer one allows it. Omitting the option makes the short case commit under the Repo default. A pre-existing checkout cannot bypass the explicit deadline. Run the local small and affected gates and full review; the hosted change class is Piece-only.
- *Kept open:* a per-statement timeout.

**1f. [ELZ-400](../../tasks/ELZ-400-oauth-client-refresh-deadline.md), `integration/oauth-client`, #886: set an opt-in transaction bound.**
- *Dependencies:* ELZ-361, ELZ-393 (after 1e). *Release:* V1B. *New external dependency:* none.
- *Contract:* the refresh transaction timeout is the declared lock wait plus `exchange_timeout_ms` plus the checked overhead budget. Check just before dispatch that the full exchange and declared persistence reserve still fit. Without the new binding key, preserve both behavior and the Repo `:timeout` Need. 1e supplies only the prerequisite; 1f completes #886.
- *Acceptance:* a rotating refresh keeps its new tokens under a Repo `:timeout` shorter than the exchange. Insufficient headroom sends no request and writes nothing. Negative controls omit the explicit option or the headroom check. Secrets, durable state and unknown outcomes: local small gate and full review.
- *Kept open:* nothing new.

**1g. [ELZ-394](../../tasks/ELZ-394-model-routing-tried-bound.md), `delivery/model-routing`, #915: bound `request.tried`.**
- *Dependencies:* ELZ-369. *Release:* V1B. *New external dependency:* none.
- *Contract sketch:* `select/3` refuses a `tried` that repeats a ref or holds more refs than the route has candidates, with `{:error, :invalid_input}`. That is the refusal the issue proposes; the task checks it against `main`. Pure.
- *Acceptance:* a duplicate ref, more refs than candidates, and exactly the candidate count. Negative control: drop the uniqueness check, and the duplicate case is accepted. `delivery/model-routing` decides after an unknown outcome (tasks/ELZ-369-model-routing.md), so it keeps the local small gate and the full review.
- *Kept open:* nothing new.

**1h. [ELZ-395](../../tasks/ELZ-395-plan-grant-overlap-and-identity.md), `domain/plan`, #885 and #884.**
- *Dependencies:* ELZ-366, ELZ-399 (after 1l). *Release:* V2. *New external dependency:* none.
- *Contract:* `create/3` preserves `:subscription_exists` for an open subscription and refuses an overlap between the first grant and an effective grant of a canceled subscription as `:grant_overlap`. The host still avoids later renewal into an older grant. `domain/entitlement` checks grant IDs across all supplied facts before filtering by tenant, so Plan qualifies the ID with the tenant, using the bounded digest format and cutover described in the task.
- *Acceptance:* a backdated replacement that overlaps, one that starts at the earlier grant's end, and one after a cancel whose grants have ended. Negative control: skip the overlap read, and the overlap case is created. Durable state and money: local small gate and full review.
- *Kept open:* several active subscriptions per tenant (Wave 9 kept open).

**1i. [ELZ-398](../../tasks/ELZ-398-dead-letter-store-resolve-generation.md), `delivery/dead-letter-store`, #701: bind `resolve/3` to a record generation.**
- *Dependencies:* ELZ-301, ELZ-397 (the finding task from the completed recheck). *Release:* V1B. *New external dependency:* none.
- *Contract sketch:* each inserted record gets a generation, which `list/3` entries return. `resolve/3` takes an optional `generation`, and both its update and its duplicate lookup match it. Without it, the behaviour is today's. The table gains a column through the Piece's migration.
- *Acceptance:* a resolve retried after purge and key reuse, with the generation, leaves the new record listed. Today's stated-limit test still holds without the generation. Isolation as `elzoo_app`. Negative control: match only `(tenant, source, message_id)`, and the reuse case resolves the new record. Durable state: local small gate and full review.
- *Kept open:* nothing new.

**1j. [ELZ-396](../../tasks/ELZ-396-run-engine-reused-action-wait.md), `assembly/run-engine`, #946: preserve the earlier occurrence's wait.**
- *Dependencies:* ELZ-127, ELZ-387, ELZ-389 (after 1a, same lane). *Release:* V1B. *New external dependency:* none.
- *Contract:* refusing a reused action ID does not erase an earlier live occurrence's lifecycle wait. The earlier occurrence can still settle normally. No format or option change. Test a dispatched tool without restart and a person wait across restart on the opt-in path; deleting the wait by action ID alone makes the original outcome late. Local small gate and full review.

**1k. [ELZ-397](../../tasks/ELZ-397-dead-letter-store-purge-unknown.md), `delivery/dead-letter-store`, #947: state the purge retry exception.**
- *Dependencies:* ELZ-301. *Release:* V1B. *New external dependency:* none.
- *Contract:* after an unknown commitment of `purge/3`, retry can delete up to another `limit` eligible records; the first result cannot be recovered. Test two successive batches with the first reply discarded, and retain the tenant, state and cutoff controls. No operation replay or library change. Local small gate and full review.

**1l. [ELZ-399](../../tasks/ELZ-399-wave9-grant-id-composition.md), Wave 9 root acceptance, prerequisite for #884.**
- *Dependencies:* ELZ-379. *Release:* V2. *New external dependency:* none.
- *Contract:* exercise nonempty, distinct, stable IDs across Plan and Entitlement on the current implementation without pinning their encoding in the root scenario. Plan's own tests own the format. This changes the root test only; local full/affected and full hosted checks.

### Level 2 — the freeze (F)

- *Dependencies:* ELZ-387, every Level 1 task, and every finding task of the rechecks that changes a Contract. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Precondition of publication:* F's task text names the four records listed in [Pre-freeze rechecks](#pre-freeze-rechecks-2026-11-25). The rechecks themselves are complete; they are reviews, not jobs. ELZ-397, the one finding task, is a dependency of F.
- *Change:* documents only, on the coordinator one-PR path. In release-plan.json:
  - the stage `later` on the 14 proposals listed above;
  - `later` and `release` in the `exclude_stages` of `V1`, `V1B` and `V2`;
  - ELZ-028's status corrected;
  - the `limit` of P11 (and of each other product in "What each product loses to `later`") names the jobs moved to `later`;
  - each gate's `status`: "frozen by F; acceptance A".

  In [roadmap.md](roadmap.md), the sentence at line 81 ("V1/V2 gates select all same-release jobs except `examples-later` and `research`"), which also names `later` and `release`. In this page, "The selected set" and "Rules of the freeze" as they stand at F's base, with the job counts and each ready row's `manifest_sha256`. The generated views.
- *Acceptance:* `check-roadmap.py` (plain, `--write`, `--live`) derives, for each gate, exactly the frozen job list that the page states (the task compares the two lists). `check-claims.py` and `git diff --check` pass, and `ci-change-class.py` prints `true`. One review checks the moved rows against the reasons above. The frozen code is the code of F's merge commit; F changes only documents, so that code is the code of its base.

### Level 3 — the acceptance of the three gates (A)

One task, because the three gates share one integrated check on one commit, and V2's prior gate is V1. It is a root consumer acceptance with no Piece output, in the form of ELZ-338, ELZ-349 and ELZ-379.

- *Dependencies:* F, and through F everything above. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Deliverables:*
  - `test/first_release_recipe_test.exs`;
  - the report `docs/research/first-release-acceptance.md`;
  - each gate's `status` in release-plan.json: "accepted by A (its task ID); the release mark follows the fixtures". The status names no commit, because a commit cannot hold its own SHA. The classifier reads the whole pull request, which holds a root test, so every head of A, the final one included, takes the full hosted check. The report names the cases it ran; the local run and its commit are in the `Local gate:` line. The exact-head hosted check of A's final head is the merge evidence, and the coordinator finds it from A's merge, not from the report.
- *Gate records,* in the report, in the order V1, V1B, V2:
  1. **Every selected job.** One table row per frozen job, with no gap. A published job gives its issue (closed as completed), its merging pull request and merge commit, and the frozen `manifest_sha256` of each output. A proposal gives its resolution from the table above. A historical V1 row gives the evidence that "The published jobs" above names. A job with none is listed as undecided evidence for the coordinator's review.
  2. **Integrated pinned check.** `mix check` with no flag passes locally (an a1.medium orb with PostgreSQL 16 and MinIO) and hosted. The hosted check runs on the exact final head. The local run is recorded in the pull request body's `Local gate:` line (the body is the record of the task, `AGENTS.md` section 5), not in the report. It covers the final head when every commit after it changes no checked input (only the report or the status text), as `AGENTS.md` section 5 allows; a later commit that changes a test or code repeats it. The report names the root tests that carry source-copy, namespace, schema and provider compatibility: the export plan of every ready Piece, the aggregate consumer, `cure_record_tags_test.exs`, `registry_test.exs` and `install_configuration_test.exs`. For provider-pin closure it names `registry/providers.json` with the install-guidance cases of `test/export_test.exs` and `test/source_only_provider_test.exs`; for cross-Piece failure evidence, the Wave 4 to Wave 9 root acceptances in `test/` with the negative controls that their reports record ([roadmap.md](roadmap.md), lines 84–86). It also names `check-claims.py` for claim-level grounding. It states the cross-release closure (`integration/search-data` to `state/tenant-isolation`).
  3. **V1B's end-to-end recipe.** One recipe package through `runtime/recipe-test`'s `run/1` on disposable PostgreSQL, with scripted Adapters. A graph root's `call` node starts an agent callable. The agent calls a Lua tool (`workflow/lua-tool` over `runtime/lua-binding` in the real `runtime/lua-sandbox`), which makes one scripted module call. The agent answers, and the graph finishes. The test asserts `outcome: :completed`, the `asked` counts, an empty `unused` and the graph's finish payload. The Lua entry states all five limits, with `wall_ms` 1,000 (the sandbox's maximum and twice the 500 ms of #547); the sandbox has no defaults.
- *Negative controls,* one at a time, each restored before the final passing run: remove the Lua tool's entry (the recipe is refused `unbound_tool`, and the recipe case fails); point the graph node at an agent that the package lacks (`workflow/recipe-check` refuses, and the case fails). The job table has no control of its own: no committed code produces it, and the reviewer checks it against release-plan.json and the issues.
- *Local gate:* `mix check`, `check-roadmap.py --live`, `check-claims.py`, `git diff --check`. Full hosted check. Full review: reviewer by risk, the strongest other-family model available.
- *Limits to state:* finite tested scenarios, not proofs. Each Piece's Limits stand. Scripted models and providers. The `later` rows and the product limits are not supplied. No complete-product claim.

### Level 4 — record fixtures written by the frozen code (X1–X3, three Piece tasks, parallel)

Each task writes its fixtures with the code at its base, and first checks that the record-writing paths (Rules of the freeze, rule 2) equal those of the ELZ-408 merge `71e5f2b9`, the refreeze baseline. The owner chose option A on #990 because the cold-VM recovery fix changed a record-writing path; ELZ-409 is an admitted test-only repair. Each commits the fixture files under its Piece's `test/` and lists them in `piece.json`. A test pins each fixture's SHA-256, so a later change adds fixtures and never rewrites one. Each updates its index row hash. *Release and stage:* V2, `release` (each depends on A). *New external dependency:* none. The exact cases are checked against `main` at publication.

**X1. `workflow/pattern-step`.**
- *Dependencies:* ELZ-114, A.
- *Fixtures:* `decode/1` and `decode/2` take two map types, a request and an input (the README's "Neutral maps"). So the fixtures are canonical JSON maps of those two, for v1 and v2: requests that together hold each action kind, and inputs of each input kind (v2 `outside_event` among them), with `action_outcome` inputs of each outcome class. Each is written by `encode/1` from a checked value. A tracker from `open/1` is opaque and is not a fixture; its v1/v2 behaviour stays covered by the Piece's existing tests.
- *Test:* each fixture decodes with `decode(map, version)` to `{:ok, _}`, and `encode/1` returns the same map.
- *Negative control:* rename one field in the decoder, and the fixture case fails.
- *Review:* low risk, one light review.

**X2. `assembly/run-engine`.**
- *Dependencies:* ELZ-127, ELZ-387, A.
- *Fixtures:* the committed DurableUnit rows of a few Runs written by the frozen engine: protocol v1, protocol v2 with an event wait, `expiry_reports: :owner`, and `messages: :while_active`. Among them are a completed Run, a paused Run and an open Run.
- *Test:* an engine started on a Store holding those rows gives the recorded `status/1`, `transcript/3` and `result/3`. The open Run takes one more input and continues. A changed start option on the same rows is `:incompatible_recovery`.
- *Negative control:* rename one control key in the reader, and recovery of the fixture fails.
- *Review:* durable state, so a local small gate and a full review.

**X3. `runtime/recipe-test`.**
- *Dependencies:* ELZ-181, ELZ-183, A.
- *What can be read today:* the one public function is `run/1` (`test/support/recipe_test_helper.exs`, line 67). Its record reader is private (`record/1`, `steps/3`, `step/1`) and reads a live engine. Only `steps` comes from the stream; `outcome` comes from `RunEngine.status/1`, and `asked`, `unused` and `restarted` from harness state. So under Q4 A the fixture is the record itself.
- *Fixtures (Q4 A):* the record that `run/1` gives for named specs (an agent, a graph with a decision, a Lua tool with `wall_ms` 1,000, and a model graph after one restart), written by the frozen code, stored as deterministic external terms.
- *Test:* `run/1` of each named spec gives exactly the committed record. A later version that changes the record form fails this test, so the change is made deliberately, under a new ID after the release. `run/1` starts its own engine and reads only that run's stream, so it reads no stored rows; the engine's stored rows are pinned by X2's fixtures.
- *Negative control:* in the worktree, rename one step kind in the private `step/1`, and the record case fails.
- *Rerun:* the same spec gives the same record by observation, not proof (the Piece's README, "No record id …": "observed in the tests, not proven"), and the Lua spec runs in a real sandbox under load, as in #547. A mismatch on a hosted run therefore takes the rerun rule of `AGENTS.md` section 5; a second mismatch of the same case is a real failure.
- *Review:* the full review: the Piece runs Runs on PostgreSQL, and its record is the format a recipe author asserts on.

### Level 5 — the release mark (M)

- *Dependencies:* X1, X2, X3. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Change:* M names its own merge commit as the release commit, subject to a green push run on that exact SHA. M names the release (as M's pull request, whose merge commit it is) in:
  - `docs/consuming.md` (a section "The first release" with the exact-SHA green-push check and checkout instructions above);
  - the two bullets of `AGENTS.md` section 4 (the owner's answer to Q2 is the ask that the coordinator guide requires);
  - docs/choices.md, "In-place change before the first release";
  - [bot-platform.md](bot-platform.md), the 2026-11-14 decision line;
  - the `status` of the three gates, by M's task ID (no pull request number, `AGENTS.md` section 3), with the `manifest_sha256` of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test` after X1–X3, since those three differ from the hashes that A recorded;
  - this page's "Status and scope".

- *Acceptance:* consuming.md is read by code, so M takes the full check. `check-roadmap.py --live`, `check-claims.py` and `git diff --check` pass. One review checks that M's base holds the merges of X1–X3, that nothing after A's head changed a Piece except X1–X3 and the admitted repairs ELZ-408 and ELZ-409, that M changes no Piece, and that the consuming instructions distinguish M's successful exact-SHA push from a later green repair. After the merge, the coordinator confirms that the push run for M's exact merge SHA is green. If it stays red after any rerun allowed by `AGENTS.md` section 5, stop: the release is not accepted, and no later commit becomes the release commit without a new owner decision.
- *From the release commit on:* the new-ID rule applies. A job published after it takes stage `later` until the owner plans a next release.

## Owner questions

Answered on 2026-11-25: all take option A (see [Owner answers](#owner-answers-2026-11-25)). The original choices are retained for context.

1. **Q1 — Where the release commit falls** (decision 3).
   - A: at the merge of the release mark M, after the freeze, the acceptance and the fixtures. Its code is the fixtures' code. The new-ID rule starts there.
   - B: at the merge of the freeze (F), the literal reading. M moves to just after F (Level 3), and the release commit is M's merge, which holds F's code, by the reason of "What the release is", and the acceptance and the fixtures follow it (Levels 4 and 5). A defect that the acceptance finds ships in the release and is repaired after it, keeping its ID when the repair restores the Contract. Under the owner's text, the new-ID rule still starts only after the fixtures, so between F and the last fixture merge a released Contract could still change in place. M would then say so in `AGENTS.md` section 4, and the start of the rule would be a second commit, the last fixture merge.

   *Recommendation: A.* The released commit then holds an accepted set and its own fixtures, and the commit that consumers take is the one the acceptance checked. Under B, the release commit could hold a defect that the acceptance then finds.
2. **Q2 — How the release is marked.**
   - A: the release commit named in consuming.md, `AGENTS.md` section 4, choices.md and the gate statuses. No tag, no version change and no changelog file.
   - B: A plus an annotated Git tag on the release commit (for example `first-release`), with one sentence in consuming.md that names it.
   - C: A plus a `CHANGELOG.md` for changes after the release.

   *Recommendation: A.* It uses only what consuming.md already supports. The receipt's `revision` identifies the commit. A tag can be added on the same commit at any later time, so B is not foreclosed. A changelog would repeat what the new-ID rule and LEDGER.md record. Any answer is also the owner's ask for M's `AGENTS.md` edit.
3. **Q3 — The Contract additions before the freeze** (#886, #915, #885 with #884, #701; #912 as option D).
   - A: all of them, as Level 1e–1i (five Piece tasks, four of them parallel).
   - B: none. #886, #885 with #884, and #701 stay stated limits or host Needs. #915 gains a stated Limit in the `delivery/model-routing` README and `piece.json` (text only, the alternative that its issue offers), so that its claim is exact. A fix after the release takes a new ID.
   - C: only #886 (1e, 1f) and #915 (1g).
   - D: A plus #912: an `integration/mcp-client` signal before its bound of 64 distinct tokens per session, or an eviction that keeps redaction, in place before the freeze (one more Piece task).

   *Recommendation: A.* Each is small, and each becomes a new ID after the release. For `state/tenant-isolation` (#886), the durable Pieces that depend on it would each have to opt in to the new ID. The overlap of #885 and the key reuse of #701 are correctness gaps in money and durable state. If speed matters more, C keeps the two cheapest, including the foundation fix. D is not recommended: #912's shipped claim is exact and tested, and its open part is a new feature.

4. **Q4 — The record fixtures of `runtime/recipe-test`** (X3).
   - A: golden records. `run/1` of named specs must give exactly the committed records. No new function, so nothing changes before F.
   - B: a public reader (an extra task, in place before F) that turns a committed engine stream into the record, so X3's test reads a stored stream, as X2's does.

   *Recommendation: A.* The engine's stored rows are already pinned by X2. recipe-test's own format is its record, which A pins without a new API in a Piece that the acceptance will have accepted. B stays addable as a new function under a new ID after the release, because it adds a capability and changes no existing Contract.

## What remains after the first release

The coordinator plans none of this here:

- **The deferred, demand-led rows:** the `later` jobs above, RC-33 to RC-41, and the deferred handles of Waves 4 to 9 without rows (the channel adapters and a payment provider among them). Each comes as a new Piece (decision 1).
- **The kept-open options** of [choices](../choices.md#deferred-options) and of each task's "Kept open" list. From the release commit, each one that changes a ready Contract needs a new ID.
- **The items that can wait,** from the table above.
- **A next release,** if the owner plans one. Its gate would select the `later` jobs that the owner names.
