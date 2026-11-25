# The first release

## Status and scope

This document is the planning input for Elzoo's first release. The Level 1 publication adds task Contracts, not implementation, and promotes nothing to ready. [release-plan.json](release-plan.json) stays the one canonical planning source. ELZ-388 is this plan. The coordinator assigns ELZ IDs at publication; F, A, X1–X3 and M do not yet have IDs. Each published task is the Contract of its work. Where a task differs from a sketch below, the task wins.

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

### Rule

The freeze changes no selector logic. It uses the existing `exclude_stages` mechanism, the way `examples-later` already works:

- `later` is the stage of each job that the first release does not wait for. That means the proposals of the next section that move to a later release, and every job published after the release commit until the owner plans a next release.
- `release` is the stage of the release's own tasks (F, A, X1–X3 and M). They accept the frozen set and are not part of it.

The freeze adds both values to the `exclude_stages` of `V1`, `V1B` and `V2`, so each gate's derived prerequisites become its frozen set. The products keep their job lists: a product is a description, and its limit says what a consumer still supplies.

### Frozen set, as of `a290e338`

The freeze task (F) rewrites this section at its own base. It counts the Level 1 tasks (stage `pieces`; their releases are named below), ELZ-388 (this plan, V2) and any further task that the coordinator ties to #930.

| Gate | Selected jobs now | Moved to `later` | Frozen jobs before Level 1 | Ready rows |
| --- | --- | --- | --- | --- |
| `V1-ACCEPT` | 113 (90 published, 23 proposals) | 7 (RC-01, RC-04, RC-06, RC-09, RC-17, RC-42, RC-43) | 106 | 70 |
| `V1B-ACCEPT` | 254 (227 published, 27 proposals) | 0 | 254 | 75 |
| `V2-ACCEPT` | 32 (21 published, 11 proposals), 33 with ELZ-388 | 7 (RC-20, RC-24, RC-27, RC-28, RC-29, RC-30, RC-31) | 25, 26 with ELZ-388 | 7 |

The frozen Pieces are today's 152 ready catalogue rows, with the `manifest_sha256` they have in `entries` at the freeze commit. A Level 1 repair changes some of those hashes before the freeze, and F records the values at its base.

- **V1 (70):** `assembly/durable-job`, `assembly/http-job`, `assembly/ingest-dedup-accumulate`, `assembly/ingest-json-unit`, `assembly/request-route-retry`, `core/assembly`, `core/edge`, `core/effect`, `core/envelope`, `core/operator`, `core/port`, `core/selection`, `core/wiring`, `delivery/aggregation`, `delivery/backpressure`, `delivery/circuit-breaker`, `delivery/data-stream`, `delivery/dead-letter`, `delivery/effect-intent`, `delivery/idempotency`, `delivery/request-reply`, `delivery/retry-timeout`, `delivery/routing`, `delivery/stream-combinators`, `delivery/time`, `delivery/transformation`, `delivery/trigger`, `delivery/windowed-idempotency`, `domain/authorization`, `integration/ai-batch`, `integration/ai-batch-anthropic`, `integration/ai-embedding`, `integration/ai-embedding-openai`, `integration/ai-model`, `integration/ai-text`, `integration/ai-text-anthropic`, `integration/ai-text-openai`, `integration/crypto`, `integration/cure-json`, `integration/http`, `integration/jobs`, `integration/json`, `integration/mcp-client`, `integration/notification`, `integration/object-store`, `integration/observability`, `integration/search-data`, `integration/secrets`, `integration/sql`, `integration/text-chunking`, `runtime/adapter`, `runtime/host`, `runtime/os-isolation`, `runtime/registry`, `runtime/supervision`, `runtime/telemetry`, `runtime/unit`, `state/artifact`, `state/audit-log`, `state/checkpoint`, `state/event-log`, `state/lease`, `state/outbox`, `state/scheduler`, `workflow/approval`, `workflow/budget`, `workflow/context-selection`, `workflow/dependency-graph`, `workflow/run`, `workflow/state-machine`.
- **V1B (75):** `assembly/checked-command`, `assembly/knowledge-ingest`, `assembly/run-engine`, `core/payload-schema`, `delivery/dead-letter-store`, `delivery/debounce`, `delivery/durable-mailbox`, `delivery/model-routing`, `delivery/provider-stream`, `delivery/rate-limit`, `delivery/room`, `domain/entitlement`, `domain/kill-switch`, `domain/membership`, `domain/metering`, `domain/principal`, `domain/provider-data-policy`, `domain/quota`, `domain/recipe-config`, `domain/recipe-graph`, `domain/recipe-package`, `domain/trigger-binding`, `integration/ai-text-compatible`, `integration/ai-text-google`, `integration/ai-token-count`, `integration/document-parse`, `integration/egress-policy`, `integration/encryption`, `integration/mcp-multi`, `integration/mcp-runtime`, `integration/mcp-server`, `integration/oauth-client`, `integration/pii-redaction`, `integration/token-verify`, `integration/webhook-in`, `integration/webhook-out`, `runtime/async-work`, `runtime/durable-unit`, `runtime/dynamic-units`, `runtime/lua-binding`, `runtime/lua-sandbox`, `runtime/recipe-test`, `state/conversation`, `state/memory-record`, `state/recipe-store`, `state/retention-erasure`, `state/tenant-isolation`, `workflow/agent-loop`, `workflow/bot-run-lifecycle`, `workflow/citation`, `workflow/context-compaction`, `workflow/delegation`, `workflow/eval`, `workflow/graph-run`, `workflow/lua-tool`, `workflow/mid-run-input`, `workflow/node-outcome`, `workflow/output-repair`, `workflow/pattern-step`, `workflow/prompt-assembly`, `workflow/recipe-check`, `workflow/run-approval-release`, `workflow/run-resource`, `workflow/runtime-graph`, `workflow/skill`, `workflow/stall-detect`, `workflow/tenant-lifecycle`, `workflow/tool-registry`, `workflow/tool-result-limit`, `workflow/turn-policy`, `workflow/typed-decision`, `workflow/untrusted-content`, `workflow/version-pin`, `workflow/wait-for-person`, `workflow/work-item`.
- **V2 (7):** `assembly/ledger-checkout`, `domain/invoice`, `domain/journal`, `domain/money`, `domain/payment-lifecycle`, `domain/plan`, `domain/pricing`.

**One release, so the cross-release closure is accepted with it.** `integration/search-data` (V1) copies `state/tenant-isolation` (V1B) into every consumer. V1-ACCEPT therefore holds only together with V1B-ACCEPT. A second reason: V1 Pieces carry in-place changes made by V1B jobs, among them ELZ-305 (`runtime/os-isolation`) and ELZ-382 (`integration/mcp-client`), so the frozen V1 code is not the V1 jobs' code alone. Because the first release passes the three gates together, nothing moves. The acceptance report states this. The job's release stays V1, and the job dependencies keep their order.

### What each still-unpublished RC job and each non-ready row becomes

Every non-ready row of a selected job either moves to `later` or is accepted as an index resolution. No RC job is kept and built for this release: under decision 1 the release waits for no deferred row. The builds it waits for are ELZ-387 and the Level 1 repairs below, and none of them is an RC job. No row is dropped from the catalogue, because the 97 baseline rows must stay and `check-roadmap.py` refuses a lost one. A `later` row stays in the inventory with its disposition.

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

- **The release commit.** The merge commit of the release-mark task M, with a green push run of `symbolic-check.yml` (Q1 A). M changes no Piece, so its Pieces are byte for byte those of the last fixture task's merge, which the acceptance and the fixtures checked. consuming.md lines 34–35 tell a consumer to take Pieces from "the latest commit of `main` whose push run … is green". When M's push run is green, that latest commit is the release commit, so the existing rule and the release agree on that day, with no new mechanism. A receipt's `revision` then names it. No marker branch is made.
- **Taking it later.** Once `main` moves on, the latest green commit is no longer the release commit. M's consuming.md section therefore says that the first release is the merge commit of M's pull request (a commit cannot name its own SHA, so the section names the pull request, and GitHub shows its merge commit). It also says that a consumer who wants the first release runs `mix elzoo.take` from a checkout of that commit, and that the latest-green rule gives the newest code instead. An export from a checkout of the release commit copies a consuming.md that holds this section, because M wrote it in that commit.
- **Its record.** The release-mark task M names the release, which is M's own merge commit. The documents name it by M's pull request; release-plan.json names it by M's task ID, because `AGENTS.md` section 3 keeps pull request numbers out of that file. Level 5 lists every place; the main ones are:
  - in consuming.md, a short section "The first release" (the pull request, and that from its merge commit a changed ready Contract has a new Piece ID with migration notes, lines 162–169);
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

Everything else waits unless the coordinator explicitly admits it before the freeze, as with #946. That covers unrelated timing flakes, which fall under the rerun rule of `AGENTS.md` section 5, other repairs that only restore a Contract (they keep the ID after the release too), and process or CI text that no Piece reads.

| Item | State at Level 1 publication | Decision | Reason |
| --- | --- | --- | --- |
| [#930](https://github.com/balungpisah/elzoo/issues/930) | ELZ-387 merged as #945 | Landed (Level 0) | Decision 2. It adds a control key to the run-engine record, so it precedes the format freeze. |
| [#821](https://github.com/balungpisah/elzoo/issues/821) | Merged as ELZ-358 (PR [#864](https://github.com/balungpisah/elzoo/pull/864), `10dfd080`); the issue is closed as completed | Landed | — |
| [#843](https://github.com/balungpisah/elzoo/issues/843) | Merged as ELZ-359 (PR [#863](https://github.com/balungpisah/elzoo/pull/863), `9580f2b1`); the issue is closed as completed | Landed | — |
| [#931](https://github.com/balungpisah/elzoo/issues/931), [#932](https://github.com/balungpisah/elzoo/issues/932) | Merged as ELZ-385 (PR #940) and ELZ-386 (PR #939); both issues are closed | Landed | — |
| [#852](https://github.com/balungpisah/elzoo/issues/852) | Open. The run-engine test "unpaired original input resumes from stored time and facts after owner-tree fencing" (`run_engine_v2_source_test.exs`) exited 2 under `--repeat-until-failure 30`: after 14 passes on the ELZ-351 head, and after 4 passes with `main`'s engine. The cause has not been investigated. | **Must land** (Level 1a) | It is in the engine's recovery, the durable path that X2's fixtures pin. If the cause is an engine defect whose fix changes a record, the fix must come before the format freeze. |
| [#834](https://github.com/balungpisah/elzoo/issues/834) | Open. Text only: the stop set of `delivery/room`'s repeated `open/3` Need. | **Must land** (Level 1b) | It is the exact Contract text of a frozen Piece, and it changes `piece.json`, so its hash must be settled before the freeze. |
| [#710](https://github.com/balungpisah/elzoo/issues/710) | Open. `runtime/os-isolation` `recover/1` can give a second result, against its README's "does not notify twice". | **Must land** (Level 1c) | The acceptance cannot accept a claim that a known defect contradicts. The fix restores the Contract. |
| [#918](https://github.com/balungpisah/elzoo/issues/918) | Open. `assembly/ledger-checkout`: the recipient half of "another amount or recipient" has no test, a host duty is missing from the `piece.json` grounding, and a README wrap. | **Must land** (Level 1d) | A Contract clause has no evidence. Test, grounding and wrap only. |
| [#886](https://github.com/balungpisah/elzoo/issues/886), [#915](https://github.com/balungpisah/elzoo/issues/915), [#885](https://github.com/balungpisah/elzoo/issues/885) with [#884](https://github.com/balungpisah/elzoo/issues/884), [#701](https://github.com/balungpisah/elzoo/issues/701) | #886 is a host Need of `integration/oauth-client`; #885 and #884 are host limits of `domain/plan`; #701 is a stated limit of `delivery/dead-letter-store`; `delivery/model-routing` states no bound on `tried` (#915). | **Must land** (Q3 A, Levels 1e–1i) | Each changes a ready Contract, so after the release each would need a new ID. For `state/tenant-isolation` (#886), every durable dependent would then have to opt in. |
| [#946](https://github.com/balungpisah/elzoo/issues/946) | Reported on #945 and reproduced without the start option. | **Must land** (Level 1j) | A refused reused action ID removes the live occurrence's lifecycle wait and lets a valid outcome be classified late. Repair the ready Piece before freezing its formats. |
| [#947](https://github.com/balungpisah/elzoo/issues/947) | One BLOCKER from the `delivery/dead-letter-store` recheck. | **Must land** (Level 1k, before 1i) | The retry wording covers a purge that can delete another batch after an unknown outcome. State the exception and test it without adding operation replay. |
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

These rules hold from the merge of F to the release commit. F writes them into this section as they stand at its base.

1. Only these merge: the release tasks; repairs that restore a ready Contract; and test-only Piece repairs (`AGENTS.md` section 1). A repair published during the freeze takes stage `release`, so the derived frozen set does not change after F, and A lists it with its commit. A change to a ready Contract, a new ready Piece or a new job in stage `pieces` of V1, V1B or V2 waits until after the release commit. New Piece tasks for deferred rows may be published and built meanwhile with stage `later`, but they merge after the release commit.
2. The record-writing paths of `assembly/run-engine`, `workflow/pattern-step`, `runtime/durable-unit` and `runtime/recipe-test` do not change. If a repair needs them to change, the release stops, and the owner decides whether to freeze again.
3. A defect that A finds is its own repair task. One that restores the Contract merges during the freeze, and A records it with its commit. One that needs a Contract change stops the release for the owner.
4. The review, exact-head check, queue and red-`main` rules are unchanged.

## Dependency levels

Each task names its new external dependency, which is "none" throughout. No provider task, pin change, PostgreSQL extension or CI service is added.

### Level 0 — landed

- **ELZ-387** (`assembly/run-engine`, `messages: :while_active`, V1B). Merged as [#945](https://github.com/balungpisah/elzoo/pull/945) at `3e72f6f9`.

### Level 1 — work that must land first (one lane per task)

Run disjoint lanes in parallel. Run 1j after 1a, 1i after 1k, 1f after 1e, and 1h after 1l.

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

Each task writes its fixtures with the code at its base, and first checks that the record-writing paths (Rules of the freeze, rule 2) equal those of F's merge commit. Each commits the fixture files under its Piece's `test/` and lists them in `piece.json`. A test pins each fixture's SHA-256, so a later change adds fixtures and never rewrites one. Each updates its index row hash. *Release and stage:* V2, `release` (each depends on A). *New external dependency:* none. The exact cases are checked against `main` at publication.

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
- *Change:* M's own merge commit is the release commit. M names the release (as M's pull request, whose merge commit it is) in:
  - `docs/consuming.md` (a section "The first release");
  - the two bullets of `AGENTS.md` section 4 (the owner's answer to Q2 is the ask that the coordinator guide requires);
  - docs/choices.md, "In-place change before the first release";
  - [bot-platform.md](bot-platform.md), the 2026-11-14 decision line;
  - the `status` of the three gates, by M's task ID (no pull request number, `AGENTS.md` section 3), with the `manifest_sha256` of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test` after X1–X3, since those three differ from the hashes that A recorded;
  - this page's "Status and scope".

- *Acceptance:* consuming.md is read by code, so M takes the full check. `check-roadmap.py --live`, `check-claims.py` and `git diff --check` pass. One review checks that M's base holds the merges of X1–X3, that nothing after A's head changed a Piece except X1–X3, and that M changes no Piece. After the merge, the coordinator confirms that M's push run is green. If it stays red after any rerun allowed by `AGENTS.md` section 5, stop: the release is not accepted, and no later commit becomes the release commit without a new owner decision.
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
