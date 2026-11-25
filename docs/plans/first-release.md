# The first release

## Status and scope

This document is the planning input for Elzoo's first release. It promotes nothing to ready and publishes no implementation task. [release-plan.json](release-plan.json) stays the one canonical planning source. The handles below (F, A, X1–X3, M and the Level 1 repairs) are provisional, and the coordinator assigns the ELZ IDs at publication. ELZ-388 is this plan. ELZ-387 and the IDs from ELZ-389 on belong to the #930 publication thread. Each published task is the Contract of its work. Where a task differs from a sketch below, the task wins.

Wave 9 is the last row of the wave table of [bot-platform.md](bot-platform.md). Its root consumer acceptance [ELZ-379](../../tasks/ELZ-379-wave9-tools-doors-models-money-acceptance.md) merged on `main` as [#933](https://github.com/balungpisah/elzoo/pull/933) at `c6fe7a8f`. Its follow-ups ELZ-380 to ELZ-386 have merged too, the last at `77569285`. The publication of ELZ-387 (#941, [#942](https://github.com/balungpisah/elzoo/pull/942)) merged at `a290e338`, whose push run 45531086555 is green. Its build is claimed on `task/ELZ-387`. This plan starts from "What remains after Wave 9" in [bot-platform-wave9.md](bot-platform-wave9.md#what-remains-after-wave-9) and from the `release_gates`, `products` and `jobs` of [release-plan.json](release-plan.json), read at `a290e338`.

The first release is one event that passes three gates together: `V1-ACCEPT`, `V1B-ACCEPT` and `V2-ACCEPT`. `V3-ADMIT` is research only and is not part of it. The plan has five steps, in this order:

1. The repairs that must land first, including ELZ-387, merge (Levels 0 and 1).
2. One documents-only task freezes the selected set and the record formats (Level 2).
3. One root acceptance task passes the three gates on the frozen set (Level 3).
4. Three Piece tasks commit the record fixtures written by the frozen code (Level 4).
5. The `main` commit where the last fixture task merges, with a green push run, is the **release commit**. One task names it in the consuming documents (Level 5). From the release commit on, the new-ID rule of `AGENTS.md` section 4 applies to every ready Contract.

The plan adds no Piece, no script, no CI job and no release mechanism that the repository's documents do not already support. Q2 asks the owner whether to add a tag.

### Settled owner decisions

These decisions are inputs of the plan, not questions:

1. **No deferred row is waited for (owner, 2026-11-25).** "The first release does not wait for any deferred, demand-led row. Neither a first chat channel nor a payment provider is chosen. They come later as new Pieces, which needs no new ID for any existing Contract."
2. **#930 takes option A (owner, 2026-11-25).** An opt-in run-engine start option, published as [ELZ-387](../../tasks/ELZ-387-run-engine-messages-while-active.md) and built in place before the release. The release depends on it.
3. **Freeze, accept, then fixtures (owner, 2026-11-25, with the decision of 2026-11-21).** "After the release, freeze the selected set and the record formats. Then run V1-ACCEPT, V1B-ACCEPT and V2-ACCEPT. Then commit the record fixtures written by the released code to the tests of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test`. From then on, the new-ID rule of AGENTS.md section 4 applies." The 2026-11-21 note in [bot-platform.md](bot-platform.md#owner-decisions-that-are-still-open) adds that the fixtures come only then: "Not before: no older format exists yet."
4. **In place before the first release (owner, 2026-11-14), and no corner (owner, 2026-11-21, standing).** Until the release commit, a ready Piece that lacks something that clearly belongs to it is extended in place under its ID. After the release commit, a change to accepted inputs, outputs, state, delivery, failure guarantees or Needs gets a new ID. A bug fix that restores the Contract keeps the ID ([AGENTS.md section 4](../../AGENTS.md#4-build)).

### A reading of decision 3, recorded for the owner to correct

Decision 3 begins "After the release" and ends with the new-ID rule applying "from then on", after the fixtures. The coordinator reads "after the release" as "for the release, once ELZ-387 and the repairs that must land first have merged". On this reading the release commit comes last: it is the merge of the last fixture task. Three things follow:

- The fixtures are "written by the released code", because the record-writing code does not change between the freeze and the release commit (see "Rules of the freeze").
- A defect that the acceptance finds is repaired before the release commit, so it does not ship.
- The new-ID rule starts at the same commit that the consuming documents name.

The literal reading puts the release commit at the freeze, with the acceptance and the fixtures after it. Q1 asks which reading the owner means.

## Source boundaries checked (at `main` `a290e338`)

These facts were read at `a290e338`. They are facts, not claims that any release step has run.

- **Gates.** `release_gates` holds `V1-ACCEPT`, `V1B-ACCEPT` and `V2-ACCEPT`. Each is "not published; frozen selected set and independent integrated acceptance required". Each selects the jobs of its `release` whose `stage` is not in `exclude_stages` (`examples-later`, `research`). `V2-ACCEPT` names `V1-ACCEPT` as its prior gate. V1 and V2 require "All selected jobs accepted or exact tested upstream/index resolution reviewed; integrated pinned mix check, source-copy/namespace/schema/provider compatibility and claim-level evidence". V1B requires that "one recipe runs end to end through the engine, the agent and graph patterns and the Lua layer with scripted Adapters, under the pinned mix check", and "does not wait for V1-ACCEPT". `scripts/check-roadmap.py` derives the selected set from the selector alone (`gate_jobs`, lines 134–136). It checks that each job dependency is in the same or an earlier release (line 66), but it does not check the dependencies in Piece manifests. [roadmap.md](roadmap.md) (lines 81–89): "Final release-acceptance issues are admitted only after the selected set is frozen."
- **Selected jobs today.** V1: 113 jobs, 90 published and 23 proposals. V1B: 254 jobs, 227 published (ELZ-387 among them) and 27 proposals. V2: 32 jobs, 21 published and 11 proposals. Excluded: RC-37 to RC-41 (`examples-later`) and RC-33 to RC-36 (`research`). Every issue of a published job is closed as completed, except #941 (ELZ-387), which is open. Twenty early V1 rows (ELZ-001 to 009, 013 to 021, 025 and 032) have the status "historical-closed; not independently reaccepted here". ELZ-028's status still says "blocked: accepted ELZ-010 and provider-fit decision required", but it merged as [#123](https://github.com/balungpisah/elzoo/pull/123) and `state/lease` is ready. "What remains after Wave 9" also lists ELZ-028 as blocked. Both are stale.
- **Catalogue today.** 176 rows: 152 ready (70 owned by V1 jobs, 75 by V1B jobs, 7 by V2 jobs), 16 not ready but owned by selected jobs, 4 deferred examples and 4 deferred research rows. Two candidate gaps (RC-42, RC-43) are outside the catalogue. Every V1B row is ready. One ready V1 Piece depends on a V1B Piece: `integration/search-data` (ELZ-082) names `state/tenant-isolation` (ELZ-270) in its `piece.json`, since the in-place change of Wave 7 Q7. The gate check does not see this, because it reads job dependencies only.
- **How a consumer takes Elzoo.** [consuming.md](../consuming.md), lines 34–35: "Take Pieces from the latest commit of `main` whose push run of the backend workflow (`symbolic-check.yml`) is green; there is no separate marker branch". Lines 162–169: a changed ready Contract gets a new Piece ID with migration notes, and "There is no silent upgrade, rollback engine or remote registry service". The receipt that `mix elzoo.take` writes (`lib/elzoo/export.ex`, lines 56–68) holds `schema_version` 1, `origin`, `revision` (the commit), `uncommitted_changes`, the selected Pieces, the providers and the file hashes. It holds no version number.
- **What does not exist.** The repository has no Git tag (`git ls-remote --tags origin` lists none), no GitHub release and no changelog file. `mix.exs` line 9 has `version: "0.1.0"`. That is the version of the harness project. No receipt reads it, and a consumer never depends on the `:elzoo` application.
- **Change class.** `docs/consuming.md` is copied into every export and is read by the export tests, so `scripts/ci-change-class.py` (line 56, `READ_BY_CODE`) never counts it as documentation. Any task that edits it takes the full check. `docs/plans/release-plan.json` and the rest of `docs/` count as documentation.
- **Record formats.** [runtime/durable-unit](../../pieces/runtime/durable-unit/README.md), line 35: "The fixed v1 encoding is an OTP external term `{1, data}`". [assembly/run-engine](../../pieces/assembly/run-engine/README.md) records each start option in the control of its `:configure` record and in the fingerprint (lines 67–79, for `expiry_reports`). ELZ-387 adds `messages: :while_active` in the same way. [workflow/pattern-step](../../pieces/workflow/pattern-step/README.md) has closed v1 and v2 maps, and its only fixture is "the fixed unequal `@v1_fixture` in the test" (line 54). [runtime/recipe-test](../../pieces/runtime/recipe-test/README.md), line 365: "The record is read from the version-1 records of the engine; a later record form needs a change here."
- **Integrated evidence already in the full check.** `test/export_test.exs` has "every ready Piece plans into one destination" and the aggregate consumer "all selected sources compile and run outside Elzoo with only upstream code paths". The suite also has `test/cure_record_tags_test.exs`, `test/registry_test.exs` and `test/install_configuration_test.exs`, plus `scripts/check-claims.py`. The Wave 4 to Wave 9 root acceptances are in `test/`. No single recipe in `runtime/recipe-test`'s tests covers a graph, an agent and a Lua tool together. The nearest are "a root graph tool node gives the object of the Lua tool", "an agent calls the Lua tool, which makes one module call" and "an agent child, a decision child and a tool node run in one graph". The Lua tool cases use `"wall_ms" => 500` (`recipe_test_lua_test.exs`, line 242), which is the limit that #547 reports failing under load.
- **Review owed.** `AGENTS.md` section 6 (lines 445–448): "The same reviewer of another model family rechecks `domain/journal`, `domain/metering` and `delivery/dead-letter-store` once". Their pull requests (#698, #696 and #699) carry only their original review records, so the rechecks are still owed. The skip list of the [coordinator guide](../development/13-coordinator.md) holds one row, #798 (`06e50161..fa99ba68`).

## The selected set

### Rule

The freeze changes no selector logic. It uses the existing `exclude_stages` mechanism, the way `examples-later` already works:

- `later` is the stage of each job that the first release does not wait for. That means the proposals of the next section that move to a later release, and every job published after the release commit until the owner plans a next release.
- `release` is the stage of the release's own tasks (F, A, X1–X3 and M). They accept the frozen set and are not part of it.

The freeze adds both values to the `exclude_stages` of `V1`, `V1B` and `V2`, so each gate's derived prerequisites become its frozen set. The products keep their job lists: a product is a description, and its limit says what a consumer still supplies.

### Frozen set, as of `a290e338`

The freeze task (F) rewrites this section at its own base. It counts the Level 1 tasks (stage `pieces`), ELZ-388 (this plan, V2) and any ELZ-389 or later that the coordinator ties to #930.

| Gate | Selected jobs now | Moved to `later` | Frozen jobs before Level 1 | Ready rows |
| --- | --- | --- | --- | --- |
| `V1-ACCEPT` | 113 (90 published, 23 proposals) | 7 (RC-01, RC-04, RC-06, RC-09, RC-17, RC-42, RC-43) | 106 | 70 |
| `V1B-ACCEPT` | 254 (227 published, 27 proposals) | 0 | 254 | 75 |
| `V2-ACCEPT` | 32 (21 published, 11 proposals), plus ELZ-388 when it merges | 7 (RC-20, RC-24, RC-27, RC-28, RC-29, RC-30, RC-31) | 26 | 7 |

The frozen Pieces are today's 152 ready catalogue rows, with the `manifest_sha256` they have in `entries` at the freeze commit. A Level 1 repair changes some of those hashes before the freeze, and F records the values at its base.

- **V1 (70):** `assembly/durable-job`, `assembly/http-job`, `assembly/ingest-dedup-accumulate`, `assembly/ingest-json-unit`, `assembly/request-route-retry`, `core/assembly`, `core/edge`, `core/effect`, `core/envelope`, `core/operator`, `core/port`, `core/selection`, `core/wiring`, `delivery/aggregation`, `delivery/backpressure`, `delivery/circuit-breaker`, `delivery/data-stream`, `delivery/dead-letter`, `delivery/effect-intent`, `delivery/idempotency`, `delivery/request-reply`, `delivery/retry-timeout`, `delivery/routing`, `delivery/stream-combinators`, `delivery/time`, `delivery/transformation`, `delivery/trigger`, `delivery/windowed-idempotency`, `domain/authorization`, `integration/ai-batch`, `integration/ai-batch-anthropic`, `integration/ai-embedding`, `integration/ai-embedding-openai`, `integration/ai-model`, `integration/ai-text`, `integration/ai-text-anthropic`, `integration/ai-text-openai`, `integration/crypto`, `integration/cure-json`, `integration/http`, `integration/jobs`, `integration/json`, `integration/mcp-client`, `integration/notification`, `integration/object-store`, `integration/observability`, `integration/search-data`, `integration/secrets`, `integration/sql`, `integration/text-chunking`, `runtime/adapter`, `runtime/host`, `runtime/os-isolation`, `runtime/registry`, `runtime/supervision`, `runtime/telemetry`, `runtime/unit`, `state/artifact`, `state/audit-log`, `state/checkpoint`, `state/event-log`, `state/lease`, `state/outbox`, `state/scheduler`, `workflow/approval`, `workflow/budget`, `workflow/context-selection`, `workflow/dependency-graph`, `workflow/run`, `workflow/state-machine`.
- **V1B (75):** `assembly/checked-command`, `assembly/knowledge-ingest`, `assembly/run-engine`, `core/payload-schema`, `delivery/dead-letter-store`, `delivery/debounce`, `delivery/durable-mailbox`, `delivery/model-routing`, `delivery/provider-stream`, `delivery/rate-limit`, `delivery/room`, `domain/entitlement`, `domain/kill-switch`, `domain/membership`, `domain/metering`, `domain/principal`, `domain/provider-data-policy`, `domain/quota`, `domain/recipe-config`, `domain/recipe-graph`, `domain/recipe-package`, `domain/trigger-binding`, `integration/ai-text-compatible`, `integration/ai-text-google`, `integration/ai-token-count`, `integration/document-parse`, `integration/egress-policy`, `integration/encryption`, `integration/mcp-multi`, `integration/mcp-runtime`, `integration/mcp-server`, `integration/oauth-client`, `integration/pii-redaction`, `integration/token-verify`, `integration/webhook-in`, `integration/webhook-out`, `runtime/async-work`, `runtime/durable-unit`, `runtime/dynamic-units`, `runtime/lua-binding`, `runtime/lua-sandbox`, `runtime/recipe-test`, `state/conversation`, `state/memory-record`, `state/recipe-store`, `state/retention-erasure`, `state/tenant-isolation`, `workflow/agent-loop`, `workflow/bot-run-lifecycle`, `workflow/citation`, `workflow/context-compaction`, `workflow/delegation`, `workflow/eval`, `workflow/graph-run`, `workflow/lua-tool`, `workflow/mid-run-input`, `workflow/node-outcome`, `workflow/output-repair`, `workflow/pattern-step`, `workflow/prompt-assembly`, `workflow/recipe-check`, `workflow/run-approval-release`, `workflow/run-resource`, `workflow/runtime-graph`, `workflow/skill`, `workflow/stall-detect`, `workflow/tenant-lifecycle`, `workflow/tool-registry`, `workflow/tool-result-limit`, `workflow/turn-policy`, `workflow/typed-decision`, `workflow/untrusted-content`, `workflow/version-pin`, `workflow/wait-for-person`, `workflow/work-item`.
- **V2 (7):** `assembly/ledger-checkout`, `domain/invoice`, `domain/journal`, `domain/money`, `domain/payment-lifecycle`, `domain/plan`, `domain/pricing`.

**One release, so the cross-release closure is accepted with it.** `integration/search-data` (V1) copies `state/tenant-isolation` (V1B) into every consumer. V1-ACCEPT therefore holds only together with V1B-ACCEPT. Because the first release passes the three gates together, nothing moves. The acceptance report states this. The job's release stays V1, and the job dependencies keep their order.

### What each still-unpublished RC job and each non-ready row becomes

Every non-ready row of a selected job either moves to `later` or is accepted as an index resolution. No RC job is kept and built for this release: under decision 1 the release waits for no deferred row, and ELZ-387 is the only new build it waits for. No row is dropped from the catalogue, because the 97 baseline rows must stay and `check-roadmap.py` refuses a lost one. A `later` row stays in the inventory with its disposition.

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
| RC-17 | V1 | `integration/agent-runner` | **Later** | Demand-led (catalogue: "defer demand-led"). `workflow/agent-loop` serves the in-process agent. |
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

**The published jobs.** The acceptance (A) records, for each published job, its closed issue, its merging pull request with the merge commit, and the ready manifest of each output at the frozen commit. This includes the 20 "historical-closed" V1 rows: they predate the current review records, and the acceptance reaccepts them by their ready outputs and by the full check on the frozen code, not by redoing their tasks. F corrects ELZ-028's status to the form of the other early rows.

## What "the release" is

The plan uses only what [consuming.md](../consuming.md), the [coordinator guide](../development/13-coordinator.md) and the export code already support:

- **The release commit.** One `main` commit with a green push run of `symbolic-check.yml`: the merge of the last fixture task (Q1 A). A consumer takes the first release by taking Pieces from that commit, as consuming.md lines 34–35 already say for any green `main` commit. A receipt's `revision` then names it. No marker branch is made.
- **Its record.** The release-mark task M names the commit in four places:
  - in consuming.md, a short section "The first release" (the commit, and that from it a changed ready Contract has a new Piece ID with migration notes, lines 162–169);
  - in the two bullets of `AGENTS.md` section 4 ("Elzoo is not released yet …" and "From the first release …");
  - in docs/choices.md, "In-place change before the first release";
  - in the `status` of the three gates in release-plan.json.

  The coordinator guide lets `AGENTS.md` change "only when the owner asks". The owner's answer to Q2 is that ask.
- **No version change.** `version: "0.1.0"` in `mix.exs` is the harness project's version. No receipt or consumer reads it. Changing it would touch a shared path, run the full check and give a consumer nothing. The release is named "the first release", and its commit identifies it.
- **No changelog file.** Everything in the first release is new. LEDGER.md at the release commit lists its Pieces, with each README's Contract, limits and grounding. After the release commit, each changed Contract is a new ID with migration notes, which the LEDGER and release-plan.json record. Q2 C would add a file.
- **No tag and no GitHub release by default.** Neither exists, and no document supports one. A tag can be added on the release commit at any later time without changing anything else (Q2 B).

## Open repairs and observations

**Rule of the cut.** Before the freeze, a change lands if it does any of the following:

- changes a ready Contract that should hold from the release (after the release commit, such a change needs a new ID, and for a foundation Piece every dependent would have to opt in);
- changes a record format of the three fixture Pieces;
- leaves a Contract claim of the frozen set without evidence;
- or comes from an owed review whose findings may change a Contract.

Everything else waits. That covers timing flakes, which fall under the rerun rule of `AGENTS.md` section 5, repairs that only restore a Contract (they keep the ID after the release too), and process or CI text that no Piece reads.

| Item | State at `a290e338` | Decision | Reason |
| --- | --- | --- | --- |
| [#930](https://github.com/balungpisah/elzoo/issues/930) | ELZ-387 is published (#941) and claimed | **Must land** (Level 0) | Decision 2. It adds a control key to the run-engine record, so it precedes the format freeze. |
| [#821](https://github.com/balungpisah/elzoo/issues/821) | Closed as completed: ELZ-358, [#864](https://github.com/balungpisah/elzoo/pull/864), `10dfd080` | Landed | — |
| [#843](https://github.com/balungpisah/elzoo/issues/843) | Closed as completed: ELZ-359, [#863](https://github.com/balungpisah/elzoo/pull/863), `9580f2b1` | Landed | — |
| [#931](https://github.com/balungpisah/elzoo/issues/931), [#932](https://github.com/balungpisah/elzoo/issues/932) | Closed: ELZ-385 (#940), ELZ-386 (#939) | Landed | — |
| [#852](https://github.com/balungpisah/elzoo/issues/852) | Open. The run-engine recovery test after owner-tree fencing fails 1 run in 4 to 30 under `--repeat-until-failure`, also with `main`'s engine. The cause has not been investigated. | **Must land** (Level 1a) | It is in the engine's recovery, the durable path that X2's fixtures pin. If the cause is an engine defect whose fix changes a record, the fix must come before the format freeze. |
| [#834](https://github.com/balungpisah/elzoo/issues/834) | Open. Text only: the stop set of `delivery/room`'s repeated `open/3` Need. | **Must land** (Level 1b) | It is the exact Contract text of a frozen Piece, and it changes `piece.json`, so its hash must be settled before the freeze. |
| [#710](https://github.com/balungpisah/elzoo/issues/710) | Open. `runtime/os-isolation` `recover/1` can give a second result, against its README's "does not notify twice". | **Must land** (Level 1c) | The acceptance cannot accept a claim that a known defect contradicts. The fix restores the Contract. |
| [#918](https://github.com/balungpisah/elzoo/issues/918) | Open. `assembly/ledger-checkout`: the recipient half of "another amount or recipient" has no test, a host duty is missing from the `piece.json` grounding, and a README wrap. | **Must land** (Level 1d) | A Contract clause has no evidence. Test, grounding and wrap only. |
| [#886](https://github.com/balungpisah/elzoo/issues/886), [#915](https://github.com/balungpisah/elzoo/issues/915), [#885](https://github.com/balungpisah/elzoo/issues/885) with [#884](https://github.com/balungpisah/elzoo/issues/884), [#701](https://github.com/balungpisah/elzoo/issues/701) | Open. Each is stated today as a limit or a host Need. | **Q3** (recommended: must land, Levels 1e–1i) | Each changes a ready Contract, so after the release each would need a new ID. For `state/tenant-isolation` (#886), every durable Piece would then have to opt in. |
| AGENTS.md section 6 rechecks of `domain/journal`, `domain/metering`, `delivery/dead-letter-store` | Owed (no recheck record on #698, #696, #699) | **Must be done before the freeze** (a review, not a task) | A finding may change a Contract, and each finding becomes its own task. The `delivery/dead-letter-store` recheck comes before 1i, so a finding can join that task. |
| Skip-list row #798 (`06e50161..fa99ba68`) | Open row | **Recheck before the acceptance** | The release should not start with an open recheck. The range is a documents publication (ELZ-334), so the recheck reads text only. |
| [#912](https://github.com/balungpisah/elzoo/issues/912) | Open. ELZ-382 ([#928](https://github.com/balungpisah/elzoo/pull/928)) states and tests the bound of 64 distinct tokens per session. | **Can wait** | The claim is exact and tested. A signal before the bound, or an eviction, would be new behaviour under a new ID. |
| [#670](https://github.com/balungpisah/elzoo/issues/670), [#669](https://github.com/balungpisah/elzoo/issues/669), [#547](https://github.com/balungpisah/elzoo/issues/547) | Open timing flakes under host load | **Can wait** | The rerun rule applies, and #670 stays unchanged by the owner's decision ([choices](../choices.md#a-flaky-elz-176-bounded_time-test-stays-unchanged-2026-11-21)). A's recipe uses the sandbox's default `wall_ms`, not #547's 500 ms. X3 records no wall-time-bound Lua case. |
| [#715](https://github.com/balungpisah/elzoo/issues/715) | Open. Notes on the recheck steps of the coordinator guide. | **Can wait** | Process text. No Piece or gate reads it. |
| [#890](https://github.com/balungpisah/elzoo/issues/890) | Open. Hosted-runner apt source. The full rerun passed. | **Can wait** | CI provisioning, not the frozen code. A failure gets the rerun rule. |
| [#98](https://github.com/balungpisah/elzoo/issues/98), [#76](https://github.com/balungpisah/elzoo/issues/76), [#70](https://github.com/balungpisah/elzoo/issues/70) | Open: the CI tracking issue, the deprioritized CI guard, and the ARM64 lane that `AGENTS.md` section 3 now forbids | **Can wait** | Not part of the release. #70 is still the owner's decision: close it, or rescope it to a GitHub-hosted runner. |

## Rules of the freeze

These rules hold from the merge of F to the release commit. F writes them into this section as they stand at its base.

1. Only these merge: the release tasks; repairs that restore a ready Contract; and test-only Piece repairs (`AGENTS.md` section 1). A change to a ready Contract, a new ready Piece or a new job in stage `pieces` of V1, V1B or V2 waits until after the release commit. New Piece tasks for deferred rows may be published and built meanwhile with stage `later`, but they merge after the release commit.
2. The record-writing paths of `assembly/run-engine`, `workflow/pattern-step`, `runtime/durable-unit` and `runtime/recipe-test` do not change. If a repair needs them to change, the release stops, and the owner decides whether to freeze again.
3. A defect that A finds is its own repair task. One that restores the Contract merges during the freeze, and A records it with its commit. One that needs a Contract change stops the release for the owner.
4. The review, exact-head check, queue and red-`main` rules are unchanged.

## Dependency levels

Each task names its new external dependency, which is "none" throughout. No provider task, pin change, PostgreSQL extension or CI service is added.

### Level 0 — in flight

- **ELZ-387** (`assembly/run-engine`, `messages: :while_active`). Published, claimed, V1B. Each task that the #930 thread publishes for #930 (ELZ-389 or later) belongs here too, if the coordinator ties it to #930.

### Level 1 — repairs that must land first (one Piece each, disjoint, parallel)

**1a. `assembly/run-engine`, #852: diagnose and repair the recovery flake.**
- *Dependencies:* ELZ-127, ELZ-385, ELZ-387 (same directory, so it starts after ELZ-387 merges). *New external dependency:* none.
- *Contract sketch:* unchanged. The task names the cause. If the test itself races, it makes a test-only repair. If the engine's fencing recovery is at fault, the fix restores the README's recovery Contract. If the fix would change a record or a control key, the task stops and says so on the issue, because that is a Contract decision before the freeze.
- *Acceptance:* `mix test pieces/assembly/run-engine/test/elzoo/run_engine_v2_source_test.exs:2048 --repeat-until-failure 200` fails on the base (record the count) and passes after the fix. Every run-engine test passes. Negative control: revert the fix in the worktree, and the repeat fails again. Durable state and unknown outcomes: local small gate and full review.
- *Kept open:* nothing new.

**1b. `delivery/room`, #834: name the stop set of the repeated `open/3` Need.**
- *Dependencies:* ELZ-348. *New external dependency:* none.
- *Contract sketch:* text only. The README and the matching `piece.json` Need line say that the host repeats `open/3` until `{:ok, _}`, until `{:mailbox, :conflict}` (returned only once the conflict release has finished), or until a step 1 or step 3 refusal. No code change.
- *Acceptance:* the existing case 2 of the room tests is named as the grounding. Every room test passes. Low risk: hosted `check-piece` and one light review.
- *Kept open:* nothing new.

**1c. `runtime/os-isolation`, #710: one result per run across an Adapter restart.**
- *Dependencies:* ELZ-029, ELZ-305. *New external dependency:* none.
- *Contract sketch:* this restores "does not notify twice". The fix makes the decision between a dead Owner and a retired row in `recover/1` on one consistent read, so an Owner that retired its row as finished after the snapshot gets no observer. No new option and no new result.
- *Acceptance:* a deterministic interleaving case in which an Owner retires between the snapshot and the liveness check: one result only. The case uses a test-only hook or forced order, not a sleep. The existing recovery cases still pass. Negative control: restore the old order, and the case gets `completed` and then `unknown{owner_exit}`. Native code and concurrency: local small gate and full review.
- *Kept open:* nothing new.

**1d. `assembly/ledger-checkout`, #918: the recipient case, the grounding line and the wrap.**
- *Dependencies:* ELZ-378. *New external dependency:* none.
- *Contract sketch:* unchanged. One scenario: an existing payment of the approved terms with another recipient is refused like another amount. The `piece.json` assumption gains the README's host duty for the allowance Needs. A README wrap.
- *Acceptance:* the new scenario passes. Negative control: compare the amount only in `same_terms?/2`, and the recipient case fails. Durable state: local small gate and one review.
- *Kept open:* nothing new.

Under Q3 A:

**1e. `state/tenant-isolation`, #886: an optional transaction timeout on `transact/3`.**
- *Dependencies:* ELZ-270. *New external dependency:* none.
- *Contract sketch:* an optional timeout, 1..600,000 ms, passed to the Repo transaction. The task checks the current argument shape on `main` and adds the option without breaking a caller. Without it, the behaviour is today's, byte for byte. Out-of-range or malformed values are refused before any query.
- *Acceptance:* a transaction that outlives a short timeout is ended at it and returns the Piece's existing unavailable result; the same transaction within the timeout commits; the default is unchanged. Negative control: drop the option on the way to the Repo, and the short-timeout case commits. Durable state: local small gate and full review.
- *Kept open:* a per-statement timeout.

**1f. `integration/oauth-client`, #886, after 1e: set its own transaction bound.**
- *Dependencies:* ELZ-361 and 1e. *New external dependency:* none.
- *Contract sketch:* the refresh transaction takes the 1e timeout. It is computed from the declared lock wait, `exchange_timeout_ms` and the Needs' time. The host Need "Repo `:timeout` must exceed …" goes away.
- *Acceptance:* a rotating refresh whose exchange takes nearly `exchange_timeout_ms` keeps its new tokens under a Repo `:timeout` shorter than that exchange. Negative control: leave the option out, and that case loses the tokens (`unavailable`). Secrets, durable state and an unknown outcome: local small gate and full review.
- *Kept open:* nothing new.

**1g. `delivery/model-routing`, #915: bound `request.tried`.**
- *Dependencies:* ELZ-369. *New external dependency:* none.
- *Contract sketch:* `select/3` refuses a `tried` that repeats a ref or holds more refs than the route has candidates, with `{:error, :invalid_input}`. That is the refusal the issue proposes; the task checks it against `main`. Pure.
- *Acceptance:* a duplicate ref, more refs than candidates, and exactly the candidate count. Negative control: drop the uniqueness check, and the duplicate case is accepted. Low risk: hosted `check-piece` and one light review.
- *Kept open:* nothing new.

**1h. `domain/plan`, #885 and #884.**
- *Dependencies:* ELZ-366. *New external dependency:* none.
- *Contract sketch:* `create/3` refuses a subscription whose first period overlaps a live or still-granting subscription of the same tenant, with a fixed named refusal (#885). For #884 the task first checks whether `domain/entitlement` and every ready store that keeps its facts key grants by tenant. If they do, the README's limit becomes that fact (text only). If not, it qualifies the grant IDs with the tenant, and the task names the format.
- *Acceptance:* a backdated replacement that overlaps, one that starts at the earlier grant's end, and one after a cancel whose grants have ended. Negative control: skip the overlap read, and the overlap case is created. Durable state and money: local small gate and full review.
- *Kept open:* several active subscriptions per tenant (Wave 9 kept open).

**1i. `delivery/dead-letter-store`, #701, after its recheck: bind `resolve/3` to a record generation.**
- *Dependencies:* ELZ-301. *New external dependency:* none.
- *Contract sketch:* each inserted record gets a generation, which `list/3` entries return. `resolve/3` takes an optional `generation`, and both its update and its duplicate lookup match it. Without it, the behaviour is today's. The table gains a column through the Piece's migration.
- *Acceptance:* a resolve retried after purge and key reuse, with the generation, leaves the new record listed. Today's stated-limit test still holds without the generation. Isolation as `elzoo_app`. Negative control: match only `(tenant, source, message_id)`, and the reuse case resolves the new record. Durable state: local small gate and full review.
- *Kept open:* nothing new.

### Level 2 — the freeze (F)

- *Dependencies:* ELZ-387, every Level 1 task, the three rechecks and every finding task of theirs that changes a Contract. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Change:* documents only, on the coordinator one-PR path. In release-plan.json:
  - the stage `later` on the 14 proposals listed above;
  - `later` and `release` in the `exclude_stages` of `V1`, `V1B` and `V2`;
  - ELZ-028's status corrected;
  - each gate's `status`: "frozen by F; acceptance A".

  In this page, "The selected set" and "Rules of the freeze" as they stand at F's base, with the job counts and each ready row's `manifest_sha256`. The generated views.
- *Acceptance:* `check-roadmap.py` (plain, `--write`, `--live`) derives, for each gate, exactly the frozen job list that the page states (the task compares the two lists). `check-claims.py` and `git diff --check` pass, and `ci-change-class.py` prints `true`. One review checks the moved rows against the reasons above. The frozen code is the code of F's merge commit; F changes only documents, so that code is the code of its base.

### Level 3 — the acceptance of the three gates (A)

One task, because the three gates share one integrated check on one commit, and V2's prior gate is V1. It is a root consumer acceptance with no Piece output, in the form of ELZ-338, ELZ-349 and ELZ-379.

- *Dependencies:* F, and through F everything above. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Deliverables:*
  - `test/first_release_recipe_test.exs`;
  - the report `docs/research/first-release-acceptance.md`;
  - each gate's `status` in release-plan.json: "accepted by A at <head>; release commit after the fixtures".
- *Gate records,* in the report, in the order V1, V1B, V2:
  1. **Every selected job.** One table row per frozen job, with no gap. A published job gives its issue (closed as completed), its merging pull request and merge commit, and the frozen `manifest_sha256` of each output. A proposal gives its resolution from the table above. A job with neither stops the task. The 20 historical V1 rows are reaccepted by their ready outputs and by the full check.
  2. **Integrated pinned check.** `mix check` with no flag passes on the task's exact head, locally (an a1.medium orb with PostgreSQL 16 and MinIO) and hosted. The report names the root tests that carry source-copy, namespace, schema and provider compatibility: the export plan of every ready Piece, the aggregate consumer, `cure_record_tags_test.exs`, `registry_test.exs` and `install_configuration_test.exs`. It also names `check-claims.py` for claim-level grounding. It states the cross-release closure (`integration/search-data` to `state/tenant-isolation`).
  3. **V1B's end-to-end recipe.** One recipe package through `runtime/recipe-test`'s `run/1` on disposable PostgreSQL, with scripted Adapters. A graph root's `call` node starts an agent callable. The agent calls a Lua tool (`workflow/lua-tool` over `runtime/lua-binding` in the real `runtime/lua-sandbox`), which makes one scripted module call. The agent answers, and the graph finishes. The test asserts `outcome: :completed`, the `asked` counts, an empty `unused` and the graph's finish payload. The Lua entry uses the sandbox's default `wall_ms`, not 500 (#547).
- *Negative controls,* one at a time, each restored before the final passing run: remove the Lua tool's entry (the recipe is refused `unbound_tool`, and the recipe case fails); point the graph node at an agent that the package lacks (`workflow/recipe-check` refuses, and the case fails); and, in a scratch run of the reconciliation, remove one merge record (that job shows as unaccepted).
- *Local gate:* `mix check`, `check-roadmap.py --live`, `check-claims.py`, `git diff --check`. Full hosted check. Full review: reviewer by risk, the strongest other-family model available.
- *Limits to state:* finite tested scenarios, not proofs. Each Piece's Limits stand. Scripted models and providers. The `later` rows and the product limits are not supplied. No complete-product claim.

### Level 4 — record fixtures written by the frozen code (X1–X3, three Piece tasks, parallel)

Each task writes its fixtures with the code at its base, and first checks that the record-writing paths (Rules of the freeze, rule 2) equal those of F's merge commit. Each commits the fixture files under its Piece's `test/` and lists them in `piece.json`. A test pins each fixture's SHA-256, so a later change adds fixtures and never rewrites one. Each updates its index row hash. *Release and stage:* V2, `release` (each depends on A). *New external dependency:* none. The exact cases are checked against `main` at publication.

**X1. `workflow/pattern-step`.**
- *Dependencies:* ELZ-114, A.
- *Fixtures:* one canonical JSON map for each v1 and v2 member: the request, each action kind, each input kind (v2 `outside_event` among them), each outcome class and a tracker. Each is written by `encode/1` from a checked value.
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
- *Dependencies:* ELZ-181, ELZ-183, X2's frozen engine (no task dependency), A.
- *Fixtures:* the engine stream of named specs (an agent, a graph with a decision, a Lua tool without a wall-time edge, and a model graph after one restart), written by the frozen code, with the record that `run/1` gave.
- *Test:* the harness's record reader gives the recorded record from the fixture stream.
- *Negative control:* change the step kind that the reader expects, and the case fails.
- *Review:* one review.

### Level 5 — the release mark (M)

- *Dependencies:* X1, X2, X3. *Release and stage:* V2, `release`. *New external dependency:* none.
- *Change:* the release commit is the `main` commit where the last of X1–X3 merged, with a green push run. M names it in:
  - `docs/consuming.md` (a section "The first release");
  - the two bullets of `AGENTS.md` section 4 (the owner's answer to Q2 is the ask that the coordinator guide requires);
  - docs/choices.md, "In-place change before the first release";
  - [bot-platform.md](bot-platform.md), the 2026-11-14 decision line;
  - the `status` of the three gates;
  - this page's "Status and scope".

  Under Q2 B, the coordinator also pushes the tag after the merge. Pushing a tag changes shared state, so the owner approves it.
- *Acceptance:* consuming.md is read by code, so M takes the full check. `check-roadmap.py --live`, `check-claims.py` and `git diff --check` pass. One review checks that the named commit is the merge of the last fixture task with a green push run, and that nothing between that commit and M's base changed a Piece.
- *From the release commit on:* the new-ID rule applies. A job published after it takes stage `later` until the owner plans a next release.

## Owner questions

1. **Q1 — Where the release commit falls** (decision 3).
   - A: at the merge of the last fixture task, after the freeze and the acceptance. The new-ID rule starts there.
   - B: at the merge of the freeze (F). The acceptance and the fixtures run after the release. A defect that the acceptance finds ships in the release and is repaired after it, keeping its ID when the repair restores the Contract.

   *Recommendation: A.* The released commit then holds an accepted set and its own fixtures, and the commit that consumers take is the one the acceptance checked. Under B, the release commit could hold a defect that the acceptance then finds.
2. **Q2 — How the release is marked.**
   - A: the release commit named in consuming.md, `AGENTS.md` section 4, choices.md and the gate statuses. No tag, no version change and no changelog file.
   - B: A plus an annotated Git tag on the release commit (for example `first-release`), with one sentence in consuming.md that names it.
   - C: A plus a `CHANGELOG.md` for changes after the release.

   *Recommendation: A.* It uses only what consuming.md already supports. The receipt's `revision` identifies the commit. A tag can be added on the same commit at any later time, so B is not foreclosed. A changelog would repeat what the new-ID rule and LEDGER.md record. Any answer is also the owner's ask for M's `AGENTS.md` edit.
3. **Q3 — The Contract additions before the freeze** (#886, #915, #885 with #884, #701).
   - A: all of them, as Level 1e–1i (five Piece tasks, four of them parallel).
   - B: none. Each stays a stated limit, and a fix after the release takes a new ID.
   - C: only #886 (1e, 1f) and #915 (1g).

   *Recommendation: A.* Each is small, and each becomes a new ID after the release. For `state/tenant-isolation` (#886), the durable Pieces that depend on it would each have to opt in to the new ID. The overlap of #885 and the key reuse of #701 are correctness gaps in money and durable state. If speed matters more, C keeps the two cheapest, including the foundation fix.

## What remains after the first release

The coordinator plans none of this here:

- **The deferred, demand-led rows:** the `later` jobs above, RC-33 to RC-41, and the deferred handles of Waves 4 to 9 without rows (the channel adapters and a payment provider among them). Each comes as a new Piece (decision 1).
- **The kept-open options** of [choices](../choices.md#deferred-options) and of each task's "Kept open" list. From the release commit, each one that changes a ready Contract needs a new ID.
- **The items that can wait,** from the table above.
- **A next release,** if the owner plans one. Its gate would select the `later` jobs that the owner names.
