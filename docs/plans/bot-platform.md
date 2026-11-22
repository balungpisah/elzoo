# Bot platform track (P13)

Owner priority, 2026-11-11: the owner selected a recipe-driven bot platform as
a concrete product aim and asked that the catalogue serve it first. This page
is the plan for that aim. It is planning input. It publishes no task, admits no
Piece and promotes nothing to ready.

[release-plan.json](release-plan.json) stays the one canonical planning source.
The tables on this page restate it for a reader; the [generated views](views.md)
and the manifest win when they differ. The [roadmap](roadmap.md) keeps the
selection policy. The admission rules of
[the capability model](../capability-model.md) apply to every job here.

## The aim in short

A consumer builds a platform where a tenant hires bots. A bot is described by
a recipe. The platform has three levels:

| Level | What it is | Who glues it |
| --- | --- | --- |
| Piece | One Elzoo Piece or Assembly | The consumer, in Elixir |
| Module | One logical part made from Pieces, with a manifest face | The consumer, in Elixir |
| Recipe | One bot or one team of bots | Lua, from modules only |

The Lua file of a recipe runs one time and gives back plain data: callables,
bindings and graphs. It is not a long-running script. Three parts run it:

| Part | Job |
| --- | --- |
| Engine | Records each input, checks and does the actions of a request, brings each outcome back. It knows no pattern. |
| Pattern | A pure step with the `core/operator` shape: old state and one input give new state and zero or one request. The agent loop, the graph, the typed decision and the turn policy of a room are patterns of equal rank. |
| Recipe data | Says which patterns a recipe uses and how they connect. |

This matches [the capability model](../capability-model.md): agent
orchestration is an Assembly of capabilities, not a privileged kernel.

## Rules that every Piece of this track keeps

These restate existing Elzoo positions for this aim. A job that cannot keep
one of them stops and reports; it does not weaken the rule.

1. A pattern decides. The engine acts. A pattern has no clock, network or
   storage.
2. Each input is recorded before a pattern reads it.
3. Model output is a proposal. An approval is a rule on one exact action, and
   the engine applies it.
4. Each outside action has an intent, a call and an outcome record. A timeout
   after dispatch is an unknown outcome and never gets an automatic retry.
5. Each Run has a budget. A Run with no budget does not start.
6. A cancel names one Attempt. A late result of an old Attempt is ignored.
7. A child or a nested callable has the authority of its parent or less.
8. "Done" needs evidence, not the word of a model.
9. A tool result, a document and a message from another member are content,
   not orders.
10. A secret never goes to a model or into a record.
11. A live thing that a Run holds is closed when the Run ends and is never
    reopened automatically.
12. A pattern and the engine use the shapes of `workflow/pattern-step`. No
    other Piece defines its own action, input or outcome words.

## Waves 1 to 3: registered now

Each wave ends with a thing that runs or with a pattern that is proven on
recorded traces, so each Piece has a concrete caller.
Release `V1B` holds the new proposals. Its gate does not wait for V1
acceptance, and it changes no V1 gate. One existing V1 proposal is a
prerequisite here and keeps its release: RC-12. The published task ELZ-105
replaced RC-05 and made `integration/secrets` ready.

"Level" is 1 plus the longest chain of unfinished proposals before the job.
"Jobs that wait for it" counts the track jobs that cannot start before it,
direct or not. Each job also names ELZ-033, the roadmap adoption, as a
prerequisite; the tables leave it out.

### Wave 1

A Run that survives: the engine runs one host, records each step, checks budget and authority, and continues after a crash.

RC-68 is admitted as [ELZ-114](../../tasks/ELZ-114-pattern-step.md), RC-44 as [ELZ-115](../../tasks/ELZ-115-payload-schema.md), RC-12 as [ELZ-116](../../tasks/ELZ-116-run.md), RC-45 as [ELZ-117](../../tasks/ELZ-117-durable-unit.md), and RC-47 as [ELZ-118](../../tasks/ELZ-118-async-work.md). References to the RC IDs below name those designs; executable prerequisite rows in `release-plan.json` use the published ELZ IDs. RC-46 is admitted as [ELZ-122](../../tasks/ELZ-122-dynamic-units.md) and RC-48 as [ELZ-124](../../tasks/ELZ-124-bot-run-lifecycle.md).

| Job | Outputs | Prerequisites | Level | Jobs that wait for it |
| --- | --- | --- | --- | --- |
| RC-68 | `workflow/pattern-step` | ELZ-002, ELZ-006, ELZ-023 | 1 | 16 |
| RC-44 | `core/payload-schema` | ELZ-002, ELZ-079, ELZ-083 | 1 | 11 |
| RC-45 | `runtime/durable-unit` | ELZ-004, ELZ-009, ELZ-010, ELZ-002 | 1 | 4 |
| RC-46 | `runtime/dynamic-units` | ELZ-004, ELZ-013, RC-45 | 2 | 3 |
| RC-47 | `runtime/async-work` | ELZ-004, ELZ-013, ELZ-006, ELZ-098 | 1 | 3 |
| RC-12 | `workflow/run` | ELZ-010, ELZ-023, ELZ-024, ELZ-026, ELZ-028, ELZ-055, ELZ-009 | 1 | 6 |
| RC-48 | `workflow/bot-run-lifecycle` | ELZ-010, RC-12, RC-68 | 2 | 4 |
| RC-49 | `workflow/run-resource` | ELZ-023, ELZ-028, ELZ-006, ELZ-022, RC-68 | 2 | 3 |
| RC-50 | `assembly/run-engine` | RC-68, RC-44, RC-45, RC-46, RC-47, RC-12, RC-48, RC-49, ELZ-002, ELZ-009, ELZ-022, ELZ-023, ELZ-024, ELZ-098, ELZ-003 | 3 | 2 |

### Wave 2

An agent that uses tools: the agent loop and the typed decision are pure steps, proven on recorded traces with the model request shape and MCP tool lists. Their first run in the engine is RC-66 in wave 3.

| Job | Outputs | Prerequisites | Level | Jobs that wait for it |
| --- | --- | --- | --- | --- |
| RC-51 | `workflow/untrusted-content` | ELZ-083, ELZ-030, ELZ-002, ELZ-003 | 1 | 5 |
| RC-52 | `workflow/tool-registry` | RC-44, ELZ-083, ELZ-079 | 2 | 6 |
| RC-69 | `workflow/tool-result-limit` | ELZ-096, RC-51, RC-68, ELZ-023, ELZ-009 | 2 | 3 |
| RC-53 | `integration/ai-token-count` | ELZ-079, ELZ-030 | 1 | 4 |
| RC-54 | `workflow/prompt-assembly`, `workflow/context-compaction` | ELZ-079, ELZ-030, RC-51, RC-53, RC-68 | 2 | 3 |
| RC-55 | `workflow/output-repair`, `workflow/typed-decision` | ELZ-002, RC-44, ELZ-079, RC-68 | 2 | 2 |
| RC-56 | `workflow/agent-loop` | ELZ-002, ELZ-079, RC-68, RC-52, RC-54, RC-69, ELZ-087 | 3 | 2 |
| RC-57 | `delivery/provider-stream` | ELZ-101, ELZ-079 | 1 | 0 |
| RC-58 | `workflow/wait-for-person`, `workflow/mid-run-input` | RC-12, RC-48, RC-68 | 3 | 0 |
| RC-70 | `workflow/stall-detect` | RC-68 | 2 | 0 |
| RC-59 | `integration/mcp-multi` | ELZ-083, ELZ-105 | 1 | 0 |

### Wave 3

A recipe in Lua: a Lua file gives callables as data, the engine runs a graph, and an author tests a recipe with scripted models.

| Job | Outputs | Prerequisites | Level | Jobs that wait for it |
| --- | --- | --- | --- | --- |
| RC-60 | `runtime/lua-sandbox` | none | 1 | 3 |
| RC-61 | `domain/recipe-graph`, `domain/recipe-package`, `domain/recipe-config` | RC-44, ELZ-026, ELZ-024, ELZ-105, RC-68 | 2 | 6 |
| RC-62 | `runtime/lua-binding`, `workflow/lua-tool` | RC-60, RC-44, ELZ-002, RC-52, RC-61, RC-68, ELZ-022 | 3 | 2 |
| RC-63 | `workflow/graph-run`, `workflow/node-outcome` | ELZ-002, RC-68, RC-61, ELZ-026, ELZ-098, ELZ-003, ELZ-006 | 3 | 2 |
| RC-64 | `workflow/recipe-check`, `workflow/runtime-graph` | RC-61, RC-52, ELZ-022, ELZ-024, RC-68 | 3 | 3 |
| RC-65 | `state/recipe-store`, `workflow/version-pin` | ELZ-096, ELZ-009, RC-61, RC-64, RC-12 | 4 | 1 |
| RC-66 | `runtime/recipe-test` | RC-50, RC-52, RC-55, RC-56, RC-60, RC-61, RC-62, RC-63, RC-64, ELZ-079, RC-68 | 4 | 1 |
| RC-67 | `workflow/skill` | ELZ-096, RC-52, RC-54, RC-56, RC-65, RC-66, RC-61, RC-69 | 5 | 0 |

Briefs with Contract, acceptance, reuse and blockers for each job are in the
[scoped job briefs](views.md#scoped-job-briefs).

## How the briefs were checked

On 2026-11-12 each Contract, acceptance and reuse text of RC-44 to RC-70 was
checked two times against the source of the ready Pieces at main `ecf822e`,
each time by independent reviewers, and the findings of both rounds are in
the texts. The reuse text names the file where a fact comes from. A worker
whose base differs from that file stops and reports; the worker does not build
on the old sentence. A brief is still a proposal: where a text says "not
verified" or "not sized", the worker checks that point first.

The status text of some published jobs in
[release-plan.json](release-plan.json) is older than main: it says "PR
pending" for merged work. Readiness is read from the registry, not from that
text. These published prerequisites of the track have ready Pieces on main:

| Job | Ready Pieces |
| --- | --- |
| ELZ-002 | `core/operator`, `core/port`, `core/assembly` |
| ELZ-003 | `core/edge`, `core/envelope`, `core/wiring` |
| ELZ-004 | `runtime/unit`, `runtime/supervision`, `runtime/host`, `runtime/adapter`, `integration/json`, `assembly/ingest-dedup-accumulate`, `assembly/ingest-json-unit`, `delivery/idempotency` |
| ELZ-006 | `delivery/backpressure`, `delivery/retry-timeout`, `delivery/dead-letter`, `delivery/time` |
| ELZ-009 | `state/event-log`, `state/outbox`, `state/checkpoint`, `integration/sql` |
| ELZ-010 | `integration/jobs`, `workflow/state-machine`, `assembly/durable-job` |
| ELZ-011 | `core/effect`, `assembly/http-job` |
| ELZ-013 | `runtime/registry`, `integration/crypto`, `integration/http`, `integration/cure-json` |
| ELZ-022 | `workflow/budget` |
| ELZ-023 | `delivery/effect-intent` |
| ELZ-024 | `domain/authorization`, `workflow/approval` |
| ELZ-026 | `workflow/dependency-graph` |
| ELZ-028 | `state/lease` |
| ELZ-030 | `workflow/context-selection` |
| ELZ-033 | none: the roadmap adoption, merged as PR #56. Every job names it as a prerequisite. Its row `core/grounding` stays planned and no job here uses that row |
| ELZ-055 | `state/audit-log` |
| ELZ-079 | `integration/ai-model`, `integration/ai-text`, `integration/ai-text-anthropic` |
| ELZ-083 | `integration/mcp-client` |
| ELZ-087 | `integration/ai-text-openai` |
| ELZ-096 | `state/artifact` |
| ELZ-098 | `delivery/aggregation` |
| ELZ-101 | `delivery/data-stream` |
| ELZ-105 | `integration/secrets` |

## Parallel work

`AGENTS.md` section 3 allows at most three workers that run Mix at one time
on one host. The track is wider than that, so the order matters more than
the width.

| Level | Jobs that can start at this level |
| --- | --- |
| 1 | RC-68, RC-44, RC-45, RC-47, RC-12, RC-51, RC-53, RC-57, RC-59, RC-60 |
| 2 | RC-46, RC-48, RC-49, RC-52, RC-69, RC-54, RC-55, RC-70, RC-61 |
| 3 | RC-50, RC-56, RC-58, RC-62, RC-63, RC-64 |
| 4 | RC-65, RC-66 |
| 5 | RC-67 |

Rules for this track:

1. **RC-68 first.** It holds the action, input and outcome shapes that 14 jobs
   use directly and 16 jobs wait for. Other admitted level-1 tasks may build
   in parallel in separate orbs; other small-gate merges wait for the RC-68
   six-point proof. A wave-1 level-2 task may publish once its own prerequisites
   merge and current main is green, without waiting for all level-1 jobs. The
   serial queue, independent review, three-small-gate limit and red-main rules
   remain in force.
2. **Order of admission.** When a worker slot is free, admit the first job in
   this list whose prerequisites are merged:
   RC-68, RC-44, RC-12, RC-45, RC-48, RC-47, RC-46, RC-49, RC-50, RC-52, RC-51, RC-53, RC-69, RC-54, RC-55, RC-56, RC-61, RC-60, RC-64, RC-62, RC-63, RC-65, RC-66, RC-57, RC-59, RC-70, RC-58, RC-67.
   Jobs that another job waits for come first. They are sorted by wave, then
   by the number of jobs that wait, then by level. Thus the engine of wave 1
   (RC-50) is not behind jobs of wave 2 or wave 3, and a free slot still
   takes a later job when no job of the current wave can start. Jobs that
   no other job waits for come last.
3. **Each job writes only its own Piece directories.** No two jobs of the
   track share a path under `pieces/`. New Pieces are found by glob, so a job
   does not edit `mix.exs` to add its Piece.
4. **One provider adoption at a time.** A change of `mix.exs`, `mix.lock` and
   `registry/providers.json` is a separate provider-prerequisite task with a
   local full check. Candidates in this track: the Lua runtime (RC-60), a
   tokenizer (RC-53) and stream support (RC-57). Never two of them at the same
   time.
5. **Pairs that agree before either starts.** RC-12 with RC-48: one Run
   outcome set and one Attempt rule, owned by RC-12. RC-44 before RC-52 and
   RC-55: one validator and one validation result per value. RC-50 with
   RC-69: the largest outcome payload in the record, and where a large tool
   result is cut. RC-45 owns the one info-message form: RC-46 delivers to it, and
   the wrap of RC-50 gives it to RC-47.
6. **Fit records start early.** RC-60 and RC-53 begin with a provider-fit
   record. It is reading work, it needs no other job, and later jobs cannot be
   sized before it exists.
7. **Jobs that no other job waits for** fill a free slot and never go before a
   job that blocks others: RC-57, RC-58, RC-59, RC-70 and RC-67.
8. RC-50 is last in wave 1. RC-66 and then RC-67 are last in wave 3.

A proposal is not permission to implement. The coordinator admits a job by
publishing its task body under the usual rules.

## Deferred rows

The admission rule of 2026-11-08 already opens each planned and deferred row
for development ([roadmap](roadmap.md), catalogue admission rule). `deferred`
is a status word. It is not a lock. This track handles the deferred rows in
this way:

| Row | Job | In this track |
| --- | --- | --- |
| `workflow/run` | RC-12 | Needed in wave 1. This adoption changes the row to `planned`: the track is its concrete caller. |
| `integration/secrets` | ELZ-105 | Needed in waves 2 and 3. It is ready on `main` through the published task ELZ-105, which replaced RC-05. |
| `domain/principal`, `integration/identity` | RC-06 | Not needed in waves 1 to 3: the engine takes the acting principal as trusted text from the host, as `domain/authorization` does. Wave 4's bounded first-party caller has a host-vouched authenticated-context Need/assumption; this does not deliver a principal Piece or provider authentication. RC-06 identity-provider work remains deferred to wave 5. |
| `domain/membership`, `domain/entitlement`, `integration/auth-policy`, `domain/policy-rules` | RC-07, RC-09, RC-20 | Wave 5 placed them. `domain/membership` is ready (ELZ-269). `integration/auth-policy` is a composition with no Piece: the host maps `domain/membership` permissions into exact `domain/authorization` rules ([Wave 5 plan](bot-platform-wave5.md)). `domain/policy-rules` stays conditional until a product supplies a finite rule schema. `domain/entitlement` is placed in Wave 6 by [bot-platform-wave6.md](bot-platform-wave6.md). |
| `domain/metering`, `domain/pricing`, `domain/quota`, `domain/journal`, `assembly/tenant-edge`, `ui/component` | RC-21, RC-23, RC-08, RC-22, RC-40, RC-31 | Wave 6, accepted ([bot-platform-wave6.md](bot-platform-wave6.md); its root consumer acceptance ELZ-323 is merged): `domain/journal` (ELZ-297), `domain/metering` (ELZ-299), `domain/quota` (ELZ-303) and `domain/pricing` (ELZ-304) are ready; `assembly/tenant-edge` and `ui/component` stay deferred. |
| `assembly/data-pipeline` | RC-39 | Wave 7, placed by [bot-platform-wave7.md](bot-platform-wave7.md): it stays a deferred example, pending its Q8; `assembly/knowledge-ingest` is the Wave 7 upload-and-transform workload. |
| `workflow/work-item`, `assembly/task-workflow` | RC-11, RC-37 | Wave 8. The same rule. |
| `delivery/model-routing`, `domain/payment-lifecycle`, `integration/payments`, `assembly/ledger-checkout` | RC-25, RC-24, RC-41 | Wave 9. The same rule. |
| `state/crdt`, `state/replication`, `assembly/device-ingest`, `assembly/consent-records`, `workflow/build-graph`, `integration/sdk`, `integration/agent-runner`, `assembly/agent-product`, `domain/saas-controls` | RC-34, RC-33, RC-35, RC-36, RC-29, RC-30, RC-17, RC-38, RC-32 | Not needed by this track. They stay as they are. |

Existing proposals that a later wave needs, and that waves 1 to 3 do not:
RC-01 (stored state across a format change, wave 4), RC-42 (durable dedup for
events in, wave 4), RC-06 (waves 4 and 5), RC-03 and RC-04 (wave 6). They are
unchanged here.

## Waves 4 to 9: Waves 4 to 6 merged

These handles are listed so that an earlier Contract does not close a door
that a later wave needs. Wave 4's registered Levels 1–4 (including Pieces
`delivery/debounce`, `domain/trigger-binding`, `assembly/checked-command`,
`state/conversation`, `integration/webhook-in`, in-place v2 event waits on
`workflow/pattern-step` / `workflow/bot-run-lifecycle` / `assembly/run-engine`,
and root consumer acceptances `ELZ-252`, `ELZ-258`, `ELZ-266`) are merged on
`main`; see [bot-platform-wave4.md](bot-platform-wave4.md) for all 24
dispositions and finite evidence limits. Wave 5's Levels 1–3 and its root
consumer acceptance `ELZ-286` are merged on `main`; see
[bot-platform-wave5.md](bot-platform-wave5.md) for its dispositions, its
closure section and its open items. Wave 6's Levels 1–3 and its root
consumer acceptance `ELZ-323` are merged on `main`; see
[bot-platform-wave6.md](bot-platform-wave6.md) for its dispositions, its
closure section and its open handoff. Wave 7 is planned in
[bot-platform-wave7.md](bot-platform-wave7.md), with one disposition for each
of its handles and its open owner questions; its tasks are published from that
page after the owner answers them. Waves 7 to 9
retain the existing serial rule: a wave is registered when the preceding wave
and its pre-registration gates are accepted. A handle with a job in brackets
is an existing catalogue row that the job owns; the one exception is
`delivery/durable-idempotency` (RC-42), which is a candidate gap and not a
catalogue row.

| Wave | It runs | Piece handles |
| --- | --- | --- |
| 4 | Events in, answers out | `integration/http-server`, `integration/signature`, `integration/event-source`, `integration/webhook-in`, `delivery/debounce`, `delivery/event-trigger`, `domain/trigger-binding`, `workflow/bot-routing`, `workflow/event-wait`, `state/schema-evolution` (RC-01), `delivery/durable-idempotency` (RC-42), `domain/principal` (RC-06), `assembly/checked-command`, `delivery/pubsub` (RC-27), `delivery/event-emit`, `delivery/event-subscription`, `delivery/poll-trigger`, `state/conversation`, `domain/end-user`, `integration/channel`, `domain/channel-identity`, `delivery/message-render`, `delivery/client-stream`, `delivery/file-upload` |
| 5 | Many tenants, safely | `domain/tenant`, `domain/membership` (RC-07), `domain/entitlement` (RC-07), `integration/identity` (RC-06), `domain/role`, `integration/auth-policy` (RC-09), `domain/policy-rules` (RC-20), `state/tenant-isolation`, `integration/encryption`, `domain/api-key`, `integration/token-verify`, `domain/environment`, `domain/provider-key`, `integration/egress-policy`, `domain/kill-switch`, `domain/data-class`, `domain/provider-data-policy`, `state/decision-log`, `state/admin-audit`, `workflow/guard-input`, `workflow/guard-output`, `workflow/guard-tool`, `workflow/output-link-check`, `integration/pii-redaction`, `delivery/rate-limit`, `delivery/fair-queue`, `state/retention-erasure`, `workflow/tenant-lifecycle` |
| 6 | Count and see ([plan](bot-platform-wave6.md)) | `integration/observability` (RC-03), `runtime/faces` (RC-04), `runtime/telemetry-events`, `runtime/trace`, `runtime/metrics`, `runtime/log`, `state/run-transcript`, `runtime/alert`, `delivery/dead-letter-store`, `state/projection`, `domain/metering` (RC-21), `domain/pricing` (RC-23), `domain/quota` (RC-08), `domain/journal` (RC-22), `domain/wallet`, `workflow/spend-alert`, `assembly/tenant-edge` (RC-40), `state/feedback`, `state/eval-dataset`, `workflow/eval`, `workflow/red-team`, `ui/component` (RC-31) |
| 7 | Remember and know ([plan](bot-platform-wave7.md)) | `domain/memory-scope`, `state/memory-record`, `workflow/memory-write-policy`, `workflow/memory-extract`, `workflow/memory-recall`, `state/cache`, `state/bot-data`, `integration/document-parse`, `integration/search-text`, `integration/ai-rerank`, `workflow/permission-mirror`, `workflow/citation`, `integration/connector-web`, `integration/connector-database`, `assembly/data-pipeline` (RC-39), `assembly/knowledge-ingest` |
| 8 | Bots talk | `delivery/durable-mailbox`, `workflow/loop-guard`, `workflow/delegation`, `workflow/handoff`, `workflow/human-escalation`, `workflow/turn-policy`, `delivery/room`, `state/shared-board`, `workflow/work-item` (RC-11), `assembly/task-workflow` (RC-37), `integration/a2a-server`, `integration/a2a-client` |
| 9 | More tools, doors, models and money | `integration/oauth-client`, `integration/webhook-out`, `workflow/client-tool`, `workflow/code-mode`, `integration/openapi-tool`, `integration/mcp-server`, `workflow/package-vetting`, `integration/connector-drive`, `integration/channel-slack`, `integration/channel-whatsapp`, `integration/channel-telegram`, `integration/channel-email-in`, `integration/ai-text-compatible`, `integration/ai-text-google`, `integration/ai-multimodal`, `integration/ai-model-catalogue`, `delivery/model-routing` (RC-25), `delivery/resequence` (RC-28), `runtime/load-shed`, `domain/payment-lifecycle` (RC-24), `integration/payments` (RC-24), `assembly/ledger-checkout` (RC-41), `domain/plan`, `domain/invoice` |

### A door that wave 1 kept open: a command with no Run (delivered in Wave 4)

`assembly/checked-command` was named during wave 1 so that wave-1 Contracts
would not close the door on administration commands outside a Run (make a
binding, invite a member, publish a version). Wave 4 delivered that Contract
in `ELZ-249` (`assembly/checked-command`) and verified Memory/PostgreSQL
composition and native `assembly/run-engine` parity in `ELZ-252`. Its ready
limits (including `low_water == 0` contiguous history recovery and host-vouched
tenant/actor context) are recorded in `pieces/assembly/checked-command/piece.json`
and feed directly into Wave 5's identity and erasure design in
[bot-platform-wave5.md](bot-platform-wave5.md).

### Subsequent waves (Waves 6–9) — pruned planning baseline

Like Waves 4 and 5, Waves 6–9 must avoid turning every named handle into a
separate Piece. Ready Pieces (`runtime/telemetry`, `integration/observability`,
`state/audit-log`, `integration/search-data`, `integration/text-chunking`,
`integration/ai-embedding`, `integration/ai-text-*`, `integration/mcp-client`,
`domain/money`, `delivery/effect-intent`) already cover a large share of the
original handle list. When each wave is drafted, start from this pruned core
rather than the unpruned 74-handle wishlist:

| Wave | Pruned core Pieces (~target) | Reused / collapsed (no new Piece) | Deferred / conditional |
| --- | --- | --- | --- |
| **6 · Count and see** ([plan](bot-platform-wave6.md), which places each handle and departs from this row for `domain/entitlement`, `state/run-transcript` and `workflow/spend-alert`) | `state/run-transcript` (carrying tree/span trace view), `delivery/dead-letter-store`, `domain/metering`, `domain/quota` (with `domain/entitlement` & `run_id`-idempotent tenant allowance reservation/settlement), `domain/pricing`, `domain/journal` (double-entry over ready `domain/money`, absorbing `domain/wallet`), `workflow/eval` (dataset-backed bot evaluation over ready `runtime/recipe-test` + `state/artifact`, absorbing `state/eval-dataset`) | `runtime/telemetry`, `integration/observability` (already ready — replaces `runtime/telemetry-events`, `runtime/metrics`, `runtime/trace`, `runtime/log`, `runtime/alert`), `state/audit-log`, `workflow/budget` (`spend-alert` is a budget threshold) | `runtime/faces`, `state/projection`, `state/feedback`, `workflow/red-team`, `ui/component` (stay consumer-driven until a concrete caller exists) |
| **7 · Remember and know** ([plan](bot-platform-wave7.md), which places each handle and departs from this row for `integration/search-text` and `assembly/knowledge-ingest`) | `state/memory-record` (absorbing `domain/memory-scope` & `workflow/memory-write-policy`), `integration/search-text` (PostgreSQL FTS/`pg_trgm`), `integration/document-parse`, `workflow/citation`, `assembly/knowledge-ingest` (service-principal Run composition over ready `document-parse` + `text-chunking` + `ai-embedding` + `search-data`) | `integration/search-data` (`pgvector`), `integration/text-chunking`, `integration/ai-embedding`, `workflow/context-selection`, Wave 5 `state/tenant-isolation` RLS (replaces `workflow/permission-mirror`), `workflow/memory-extract` & `workflow/memory-recall` (pure pattern/module steps over `state/memory-record` + `search-data`) | `state/cache`, `state/bot-data`, `integration/ai-rerank`, `integration/connector-web`, `integration/connector-database`, `assembly/data-pipeline` |
| **8 · Bots talk** *(held on G10 room-life decision)* | `delivery/durable-mailbox` (Store/outbox-backed bot & room mailbox), `workflow/turn-policy`, `delivery/room`, `workflow/delegation` (absorbing `handoff`, `loop-guard`, `human-escalation`), `workflow/work-item` | `assembly/run-engine` (unchanged Contract; rooms roll over before the 256-action cap via host-owned rollover to a new Unit carrying bounded summary state), `state/conversation` | `state/shared-board`, `assembly/task-workflow`, `integration/a2a-server`, `integration/a2a-client` (only when a concrete external A2A peer exists) |
| **9 · More tools, doors, models and money** | `integration/oauth-client`, `integration/webhook-out`, `integration/mcp-server`, `workflow/code-mode` (Lua-first over ready `runtime/lua-sandbox`), `integration/ai-multimodal`, `integration/ai-text-compatible` / `integration/ai-text-google`, `delivery/model-routing`, `domain/payment-lifecycle` + `integration/payments` (over ready `domain/money` + `delivery/effect-intent`, preferring no-custody / sub-account split settlement) | `integration/ai-text-anthropic`, `integration/ai-text-openai`, `integration/webhook-in`, `domain/money`, `delivery/effect-intent`, `domain/journal` (Wave 6) | Individual channel adapters (`slack`, `whatsapp`, `telegram`, `email-in` — build each concrete channel as consumer demand arrives, starting with the first active channel), `integration/openapi-tool`, `workflow/package-vetting`, `integration/connector-drive`, `domain/plan`, `domain/invoice`, `runtime/load-shed` |

### A decision that wave 8 waits for: the life of a room

Wave 8 is not registered before the owner confirms this point. The coordinator
asks the owner first, and records the answer here.

The ready `assembly/run-engine` (ELZ-127) gives one Unit "64 active/256
lifetime actions". Its README says: "The per-Unit 256 lifetime-action limit
is not reset by that period." After 256 actions the engine refuses the next
request of that host. A Run has a request cap of at most 256 and ends. A room
is one host that lives long, so a room reaches the limit.

Two candidates are known (recommended default: candidate 1 — consumer/room
rollover to a fresh host Unit, keeping `assembly/run-engine`'s Contract
unchanged):

- **Recommended:** The consumer (or Wave 8 `delivery/room`) starts a new host
  identity for the room before hitting 256 actions and carries the bounded
  summary state over. `assembly/run-engine` keeps its ID and Contract.
- Alternative: A dedicated Wave 8 migration Piece moves a room across Units
  while keeping `assembly/run-engine`'s ID and Contract unchanged.

## What stays with the consumer

The consumer writes these and Elzoo does not: the bot records (definition,
instance and its life cycle), the public API, the screens, the developer
tools, tenancy policy, deployment, backup and release.

## Names

- `workflow/pattern-step` holds the shared shapes. `workflow/agent-loop`,
  `workflow/typed-decision` and `workflow/graph-run` are pattern steps in that
  shape. `assembly/agent-product` (RC-38) stays the later example Assembly and
  is not a prerequisite of this track.
- A new ID is used wherever a ready Contract must grow: `runtime/durable-unit`,
  `runtime/dynamic-units`, `workflow/bot-run-lifecycle`,
  `delivery/provider-stream` and `integration/mcp-multi`. The ready Pieces
  keep their IDs and Contracts. No job of this track edits a ready Piece.
- Handles are provisional until publication and can be renamed then.

## Owner decisions that are still open

Each one is a blocker on the named job, not on the track.

Resolved on 2026-11-12; these decisions are also in the corresponding job Contracts in `release-plan.json`:

- **RC-68:** version 1 has nine action kinds: model call, tool call, local work, ask a person, run a nested callable, open a run resource, use a run resource, close a run resource, finish. The three resource actions stay distinct because the engine checks and performs them differently.
- **RC-68 exclusions:** start a child Run, wait for an outside event, a part of an answer to a channel, a message to another member, make or remove a binding, give an inside event, and give a run resource to a person enter only in later versions with the wave that performs them. Ask for an approval and fill a secret are never action kinds: the engine does them. RC-48 still includes child-Run and outside-event waits in its total decision, supplied as test data; no version-1 action opens them.
- **RC-68 versions:** new versions of all three sets only add members, never change or remove them; records written under older versions stay readable. Outcome classes remain as in the Contract. Input kinds add `wake`: no content, only engine-read time, used by the host's durable timer. RC-58 must never route wake through its mid-run-input policy.
- **RC-68 person answers:** a person's answer remains its own input kind, names exactly one ask-a-person action and carries the verified person's identity. That action gets no other completed outcome. Text without an open ask is a new message.
- **RC-48:** time limits continue to count during pause, and pause has its own time limit. The person continuing a Run can give it a new time limit in the same recorded action.
- **RC-49:** a nested callable in the same Run may use a resource only when the outer node gives its name in typed input. A child Run cannot use its parent's resource. Each resource declares stay or close on pause; the default is stay until its own time limit, with cost recorded even when budget is empty. Moving ownership to a different Run is a later form; this Contract neither implements nor rules it out.
- **RC-59:** the server bindings remain build-time. Tenant-added servers need a new one-server runtime-endpoint Piece under integration/egress-policy in wave 5, bearer first; OAuth with integration/oauth-client waits for wave 9. Lists belong to server and credential: RC-59 uses one tenant credential per server and keys lists by tenant and server; future per-person credentials require separate lists. The [MCP tools specification, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/server/tools) says lists MAY vary by authorization.
- **RC-65 and RC-56:** version-pin captures the Run's source set at startup from the pinned recipe and then-read tenant settings. No model, tool or person adds sources; changed settings affect the next Run, and even an explicit version-pin change does not alter the captured set. Known-source tool lists may change. Listing an outside source is refused without changing the snapshot.
- **RC-67:** use the [Agent Skills specification](https://agentskills.io/specification), accessed 2026-11-12 (no spec version): a folder with SKILL.md, required YAML frontmatter and Markdown body; name is 1–64 characters, lowercase alphanumeric or hyphens, no leading, trailing or consecutive hyphens, and matches the folder; description is 1–1024 characters. Malformed skills are refused at package checking. V1 uses only the recipe package; MCP io.modelcontextprotocol/skills is out of scope, and future use requires person approval of the exact digest. `allowed-tools` grants no authority; scripts are stored and read, never executed in v1.
- **Skill trust and bounds:** the pinned package manifest source, not the path or result shape, establishes trust. Named skill instructions rank with recipe role instructions; RC-54 builds them as instructions and never drops them, and RC-51 does not mark them. Other tool results stay marked content. RC-56 accepts declarations only from the resolved source kind in the registry snapshot: pinned-package skill instructions or host listing tools. It owns a total loaded-instruction byte bound and named refusal alongside the 64-tool bound; admission proposes the number considering ai-text's 65,536 canonical-byte request cap. An overbound load adds no instruction, instructions are never cut, and reloading an already loaded skill adds nothing. RC-69 may cut skill files, never the SKILL.md body. RC-61's package manifest declares each skill's version and tools; the public format has no tools field.

Resolved on 2026-11-14; these decisions are also recorded in `release-plan.json` and the published tasks:

- **Pieces before the first release (owner, 2026-11-14):** Elzoo is not released yet. A ready Piece that lacks something which clearly belongs to it is extended, refactored or cut clean in place, with the same Piece ID; no second ID is made for it. The new-ID rule of `AGENTS.md` section 4 applies from the first release. First use: ELZ-172 makes `assembly/run-engine` give the result of a nested callable to its parent; RC-66 depends on it.
- **RC-60, helper set (owner, 2026-11-14):** the safe helper set is part of `runtime/lua-sandbox` as policy version 2 (ELZ-174), by the rule above. This replaces option A below, which made `runtime/lua-stdlib` a separate Piece: that planned ID is removed when ELZ-174 merges. The host stays one C file with one capability list and one policy identity. RC-62 and RC-66 depend on RC-60 with policy version 2.
- **Libraries (owner, 2026-11-14):** where a maintained library does the work, a Piece adopts it as a dependency; a reader is not written by hand. First use: ELZ-176 adopts `yaml_elixir` with `yamerl` as the YAML reader for the skill frontmatter of RC-67, as a provider prerequisite with the full check.
- **RC-62 (coordinator admission):** three tasks. ELZ-177 extends `runtime/lua-sandbox` in place (policy version 3): the sandbox answers a binding call itself, with data at load time and with the recorded results in order at run time, so there is no callback into the caller. ELZ-178 is `runtime/lua-binding` and ELZ-179 is `workflow/lua-tool`. A refused argument is located by the function name and the structural path of `core/payload-schema`, which hides member names on purpose; no second validator is written. The ready engine has one binding for each action kind, and each pattern reads its own result form: a Run that mixes patterns needs the engine to choose a binding by the schema of the action, which is its own in-place task before RC-66, and a nested child is wrapped by the host so that its finish has the form of its parent.
- **Engine bindings (coordinator admission):** ELZ-180 is that in-place task on `assembly/run-engine`: for an action kind the host gives one binding or a map from the schema ID of the action to a binding. The choice uses the schema ID only, an empty map is refused at start, and a value that is both a binding and a map is refused. RC-66 depends on it.
- **RC-66 and RC-67 (coordinator admission):** RC-66 is two tasks on one Piece: ELZ-181 is `runtime/recipe-test` with the scripted Adapter, the driver, the step record and the glue for agent, decision and graph callables; ELZ-183 adds, in place, Lua tools, graphs that a model gives and the restart. The harness ships the glue that turns the finish of a nested child into the form of its parent. RC-67 is ELZ-182, `workflow/skill`: the frontmatter is read with the adopted YAML library behind a scan that refuses aliases, merge keys, document markers, duplicate top-level keys and tabs; ELZ-182 listed no tool; ELZ-235 lists the declared tools of a loaded skill from descriptors that the host gives, and a load that would pass 64 tools is refused whole with the named refusal of RC-56 (no change of `workflow/agent-loop` is needed for that); ELZ-236 lets an agent start name one skill, so that a decision node can choose it; ELZ-237 shows both with the harness; the Piece stores nothing. With this publication every job RC-60 to RC-67 of wave 3 is published.
- **RC-60:** reference PUC Lua 5.4.9 runs outside the VM over a Port with a small C host, following ELZ-159. ELZ-160 adopts the official mirror commit with byte-identical library sources; the absent `luac.c` is not needed. The provider prerequisite does not decide capability policy. Owner decision (option A), 2026-11-14: ELZ-163 ships policy version 1 without helpers and refuses every helper name as `unlisted_name`, an exception to RC-60's every-policy-version helper requirement. The separate `runtime/lua-stdlib` Piece adds safe JSON/text/time helpers in the next policy version. RC-62 and RC-66 retain their dependency on RC-60's remaining lua-stdlib portion, so recipes never use the helper-free version.
- **RC-61:** callable kinds v1 are graph, agent and typed decision. Node kinds v1 are `call`, `tool`, `ask`, `decision`, `map` and `loop`. Map and loop are bounded re-runs of a named callable and never a back-edge. The handle remains `domain/recipe-graph` even for an agent or decision root. ELZ-161 and ELZ-162 are independent; recipe-package follows in a later publication.
- **RC-63 and RC-64 (coordinator admission):** each job is published as two tasks, one Piece each. ELZ-166 is `workflow/node-outcome`, the rule for one settled node; `workflow/graph-run` follows and calls it. ELZ-167 is `workflow/recipe-check`, the load-time check; `workflow/runtime-graph` follows and reuses it. The recipe data of RC-61 holds no cost, no tool requirement and no tenant grant, and its validators give one reason with no path. So ELZ-167 takes these as facts from the caller, compares needs and permissions as opaque strings without a call of `domain/authorization`, and locates a structural fault at its part of the package, not at its node.
- **RC-63 and RC-64, second portions (coordinator admission):** ELZ-168 is `workflow/graph-run` and ELZ-169 is `workflow/runtime-graph`. The map and loop nodes of RC-61 hold only a callable and a maximum, so the caller of graph-run supplies the concurrency bound and the part-failure rule of each map; the collection is the need named `items`, and a loop continues while its callable says so. graph-run writes its own join, skip and map-count rules over recorded outcomes and calls neither `workflow/dependency-graph` nor `delivery/aggregation`. For a model graph the host supplies what the recipe does not hold: the callables and tool sources of the agent, its depth and its budget share. ELZ-167 gained `check_graph/3` so that load time and run time use one checker.
- **RC-65 (coordinator admission):** two tasks. ELZ-170 is `workflow/version-pin`, the pure rule; ELZ-171 is `state/recipe-store`. The store runs `workflow/recipe-check` itself as the check gate and records the verdict. A package identity is not a valid artifact ID, so the store uses its 64 hex characters. The tenant stream has a fixed bound and no compaction in this task; a pin is a record, not a lease.

Resolved on 2026-11-20 (owner); these decisions govern Wave 5 ([bot-platform-wave5.md](bot-platform-wave5.md)) and its published tasks:

- **Wave 5 foundation and identity (owner, 2026-11-20):** core Wave 5 Pieces are plain Elixir/Cure/Ecto/Postgrex with the already locked `jose 1.11.13`; no Ash wrapper and no identity provider in core. Tokens and API keys are verified offline against pinned keys (ELZ-268); OIDC or passkey login stays a consumer recipe. First use: ELZ-267 and ELZ-268.
- **Unavailable or unknown policy results (owner, 2026-11-20):** a missing, timed-out or unresolvable policy or context check is `DENY`. A typed abstention from an external standing or trust provider goes to `ASK` (dual control through `workflow/approval`) only where a rule declares that routing, and is never read as `0` or distrust; otherwise it is `DENY`.
- **Erasure (owner, 2026-11-20):** statutory erasure uses a PII vault with per-subject (or per-tenant) keys and crypto-shredding. Command, event and audit logs carry opaque IDs and are never deleted or rewritten, so `assembly/checked-command` (`low_water == 0`) and Carbonite `state/audit-log` history stay intact. First use: Level 3 `state/retention-erasure`.
- **Wave 5 Level 2 scope (owner, 2026-11-20):** (1) only an agent's membership permissions are capped by its `allowed_scopes`/`allowed_spaces`; a human or service principal's memberships are its authority (ELZ-269). (2) One-use invitations leave `domain/membership` and come in Level 3 `workflow/tenant-lifecycle` as a durable checked command. (3) `integration/egress-policy` ships no fetch helper; redirects and response bounds stay transport duties (ELZ-271). (4) `integration/encryption` is one AES-256-GCM layer under the per-subject key, with no wrapped data keys (ELZ-273). (5) AES-256-GCM only; no ChaCha20-Poly1305.
- **Wave 5 Level 3 scope (owner, 2026-11-20):** (1) `workflow/tenant-lifecycle` is a Piece (ELZ-284), a pure CheckedCommand preparer that also holds one-use invitations, not a bare composition. (2) The test databases get one fixed role `elzoo_app` (`NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE`), granted to `elzoo_test` for `SET ROLE` only, so the row-security non-owner boundary is exercised in CI; `elzoo_test` gains no attribute (ELZ-285). (3) The kill-switch reason prefix `lifecycle` is reserved for `workflow/tenant-lifecycle` (ELZ-281, ELZ-284). (4) The Wave 5 root acceptance (ELZ-286) does not compose Carbonite `state/audit-log` and states that as a limit. Coordinator choices the owner kept: RC-59 is two tasks (ELZ-282 extends `integration/mcp-client` in place, then ELZ-283 `integration/mcp-runtime`); `state/retention-erasure` (ELZ-279) defers artifact and search-data tombstones and expiry; ELZ-286 does not compose `delivery/rate-limit`.

Resolved on 2026-11-21 (owner); these decisions govern Wave 6 ([bot-platform-wave6.md](bot-platform-wave6.md#provider-prerequisites-and-open-questions)) and its published tasks:

- **Wave 6 questions (owner, 2026-11-21):** Q1, Q2, Q4, Q6, Q7, Q8 and Q9 take option A of the Wave 6 plan: Piece-owned plain Ecto tables under `state/tenant-isolation` for metering, quota and the dead-letter store (Q1); unit-tagged usage per provider and model, no tiers yet (Q2); owner-authored decimal-string rate cards, `llm_db` prices a reference only (Q4); the UTC calendar month with no carry-over (Q6); deterministic scripted eval cases (Q7); no Run or model metrics in Wave 6 (Q8); `assembly/tenant-edge` stays a deferred example (Q9). First use: ELZ-299 to ELZ-302.
- **Currency and rounding (owner, 2026-11-21, Q3):** option A, plus a required per-card `rounding` field that takes one of the `domain/money` rounding modes; rounding is still once per priced line per period. No platform currency.
- **Billing model (owner, 2026-11-21, Q5):** option C, both postpaid and prepaid, shown in the Wave 6 root acceptance only; no Piece is configured for it.
- **Plan types (owner, 2026-11-21):** pay-as-you-go, quota-capped and prepaid are compositions of Pieces, not Pieces or Assemblies. The Level 3 acceptance has one named group for each, and [choices](../choices.md) holds a composition guide. Subscriptions wait for Wave 9 (`domain/plan`, `domain/invoice`).
- **No corner (owner, 2026-11-21, standing):** Elzoo may serve many kinds of consumer, so every Wave 6 Contract leaves each deferred option addable in place before the first release without breaking existing callers: closed sets that can gain members, records and results that can gain keys, no hard-coded single currency and no single plan shape. The options kept open are volume tiers, tenant-local month and rolling-window periods, a reusable `assembly/tenant-edge` over the public interfaces, Run and model telemetry metrics, and a tenant holding more than one active plan.

Resolved on 2026-11-21 (owner), from the evaluation of the Continuum library (Hex `continuum` v0.9.3, not adopted; see [dependencies](../dependencies.md#external-library-candidates)) and of Temporal's documented model (docs.temporal.io, read on 2026-11-21; not adopted: Elzoo has no mandatory global runtime, and `delivery/effect-intent` never resends on its own and permits a later explicit dispatch only after a recorded definite failure); these are drafting notes for later waves and the first release, not Contracts:

- **Wave 8 room rollover (owner, 2026-11-21):** `delivery/room` and `delivery/durable-mailbox` treat a room rollover as a continuation chain. One atomic step closes the old Run and creates exactly one successor. The chain carries one correlation ID, and each Run links to the Run before it. Mail sent to a superseded identity goes to the live tip of the chain. This fits the recommended candidate 1 of the [room-life decision](#a-decision-that-wave-8-waits-for-the-life-of-a-room), which stays open; `assembly/run-engine` keeps its Contract.
- **Wave 8 recipe version (owner, 2026-11-21):** a child Run and a room-rollover successor keep the pinned recipe version unless an explicit change says otherwise, so a rollover never moves a room silently to a newer published version. Applies to `workflow/delegation` and `delivery/room`; `workflow/version-pin` keeps its Contract when the host passes the pinned version at start.
- **Wave 8 parent-close rule (owner, 2026-11-21):** `workflow/delegation` gives each child Run a rule for a parent that ends while the child is still open: abandon, request cancel (the default) or cancel.
- **Wave 8 closed input surface (owner, 2026-11-21):** `delivery/durable-mailbox` accepts only declared message names, each with its validator. A message with an undeclared name, or one that fails its validator, is refused before the mailbox write.
- **Wave 9 saga rules (owner, 2026-11-21):** `assembly/ledger-checkout` and `domain/payment-lifecycle` register each compensation with the step that succeeded. Compensations run in reverse order by default and in parallel only where declared. Each compensation is idempotent with its own key, and a failed compensation is its own recorded outcome.
- **Wave 9 retry delay from the failure (owner, 2026-11-21):** `delivery/retry-timeout` gains, in place, a retry delay taken from the failure, such as a Retry-After value or a rate-limit wait, plus optional jitter, for results that were not dispatched only; a possibly dispatched result keeps today's rule. First caller: Wave 9 `delivery/model-routing`. A published task changes the ready Contract.
- **Deferred until a caller needs them (owner, 2026-11-21):** more schedule policies for `state/scheduler` (pause after a failed occurrence, a maximum number of occurrences, run now, jitter, the last result handed to the next occurrence); a ramped rollout of a recipe version; a progress heartbeat for `runtime/async-work`, likely first for Wave 7 `assembly/knowledge-ingest`; a business-key reuse rule for `assembly/durable-job`; and a Nexus-style call shape (callers name an endpoint, completion and cancel by token) for the Wave 8 a2a Pieces.
- **First release, frozen record fixtures (owner, 2026-11-21):** when the first release freezes the record formats, the tests of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test` gain committed record fixtures written by the released code, so a later version must still read them. Not before: no older format exists yet.

Resolved on 2026-11-22 (owner); these decisions govern Wave 7 ([bot-platform-wave7.md](bot-platform-wave7.md#provider-prerequisites-and-open-questions)) and its published tasks:

- **Wave 7 questions (owner, 2026-11-22):** "All recommended": Q1–Q9 take option A and Q10 option B of the Wave 7 plan: plain text, Markdown and HTML, with HTML through `floki 0.38.5`, to be adopted as a direct dependency by its own task (Q1); PostgreSQL built-in full-text search in place on `integration/search-data`, one text search configuration per index, no `pg_trgm` (Q2); the host fuses vector and lexical ranks by reciprocal rank, no rerank provider (Q3); a closed tagged memory scope set `{:tenant}`, `{:space, id}`, `{:subject, id}`, `{:bot, id}` (Q4); forget deletes the content and keeps a tombstone, subject erasure forgets every record of the subject, personal values go through `integration/pii-redaction` tokenize mode with the `state/retention-erasure` vault (Q5); a host write policy per scope kind, kind and writer kind with deny for an unlisted triple (Q6); an optional `state/tenant-isolation` floor in place on `integration/search-data` (Q7); `assembly/knowledge-ingest` gets its own Piece ID and RC-39 stays a deferred example (Q8); a throttled or overloaded embedding call gets a new, recorded attempt up to a declared `max_attempts` (Q9); recall by meaning as a root-acceptance composition over a search-data memory index (Q10 B). The conditional `pg_trgm` prerequisite (Q2 B) is not taken. The answer did not restate the standing "no corner" rule of 2026-11-21; the coordinator applies it to each Wave 7 Contract at publication. First use: ELZ-331 and ELZ-332; ELZ-330 (in publication) adopts `floki`.

| Decision | Job |
| --- | --- |
| Confirm room rollover default (fresh Unit before 256 lifetime actions of `assembly/run-engine`) | not registered (wave 8) |
| The turn policies of a room | not registered (wave 8) |
| The language of model-written code | not registered (wave 9) |

## Check

```sh
python3 scripts/check-roadmap.py
python3 scripts/check-roadmap.py --self-test
mix elzoo.ledger --check
```
