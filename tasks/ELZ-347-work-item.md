# ELZ-347 — A durable record of one delegated item: its intent, the child Run it is assigned to, the child's result as evidence, and acceptance by the parent

- Phase: Wave 8 Level 1
- Dependencies: ELZ-033, ELZ-137, ELZ-270, ELZ-285
- Release: V1B
- Output: `workflow/work-item` (the deferred catalogue row, narrowed; this task replaces the proposal RC-11, as ELZ-105 replaced RC-05)
- Change class: Piece-only
- Owned paths: `pieces/workflow/work-item/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `state/tenant-isolation`, `workflow/untrusted-content`, `workflow/delegation` and `workflow/run`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16: the record of one item that a parent Run delegated to one child Run, with its stable intent, its assignee, its parent-close rule, an explicit lifecycle with a revision, the child's result offered as evidence, and acceptance or rejection by the parent Run's principal. A Run result is evidence offered for acceptance, never completion (rule 8 of [bot-platform.md](../docs/plans/bot-platform.md)). The Contract source is the `workflow/work-item` section of [the Wave 8 plan](../docs/plans/bot-platform-wave8.md) ("Level 1"), under owner answer Q4 A (2026-11-23; [choices](../docs/choices.md#wave-8-owner-choices-2026-11-23)). The table is Piece-owned and protected by `state/tenant-isolation` (ELZ-270), the precedent of `domain/metering` and `state/memory-record`.

This task narrows RC-11 ("Work Item has stable intent, acceptance revision, assignee/authority and explicit lifecycle. A Run result is evidence offered for acceptance, never automatic business completion") to one item per child Run. RC-11's dependencies ELZ-026 (dependencies between items) and ELZ-028 (completion bound to a lease) are not needed by Wave 8 and stay addable (kept open). The plan's ELZ-024 and ELZ-116 are not dependencies: the library calls neither `domain/authorization` nor `workflow/run` (a coordinator check against `main`); the parent-close values restate those of `workflow/delegation` (ELZ-346, a Level 1 task of the same publication), which this Piece does not call.

The Piece keeps durable state, serializes concurrent decisions, keeps tenant content apart under row security and stores an untrusted intent, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6); the hosted `check-piece` run does not replace the local run.

## Facts on `main` that this task builds on

Checked at `main` `bce5ea99`: `Elzoo.UntrustedContent.decode/1` is the only way to make a marked value and gives `{:ok, marked}` or `{:error, :invalid_shape}`; `encode/1` gives the six-key neutral map, and `decode/1` of it gives an equal value. `Elzoo.TenantIsolation.transact/3`, `Migration.install/1`, `Migration.protect/2` and `verify/3` are as `domain/metering` and `state/memory-record` use them (tenant IDs 1..128 bytes of valid UTF-8 without a C0 or C1 control character; a caller's open transaction refused). `workflow/run` Run IDs are nonempty UTF-8 without NUL of at most 200 bytes, and its `cancel` targets exactly one Attempt.

## Interface

Module `Elzoo.WorkItem`.

- `Elzoo.WorkItem.Migration.install(prefix)`, called from a consumer migration's `up/0` by the table owner, installs the `state/tenant-isolation` readers in `prefix`, creates one item table in the existing schema `prefix` with `PRIMARY KEY (tenant, item_id)`, `UNIQUE (tenant, child_run_id)` and an index on `(tenant, parent_run_id, item_id)` for the open items, and protects it with `Elzoo.TenantIsolation.Migration.protect/2` (`space_column: nil`). `prefix` follows the tenant-isolation identifier rule; anything else raises `ArgumentError` with one fixed message before any DDL.
- `new(opts)` takes exactly `repo:` and `prefix:` and returns an items value, or raises the same fixed `ArgumentError`. `verify(items)` runs `Elzoo.TenantIsolation.verify/3` for the table and returns its result.
- An **item** is `%{item_id, parent_run_id, child_run_id, owner, intent, acceptance, parent_close, state, revision, evidence, decided_by}`: `owner` the ID of the parent Run's principal (host-vouched); `intent` a marked value whose content is 1..4,096 bytes, stored whole and returned as its neutral map with trust class, sources and bound; `acceptance` `:parent`, the one member of a closed set in this version; `parent_close` `:abandon`, `:request_cancel` or `:cancel`; `state` below; `revision` an integer from 1; `evidence` `nil` or an opaque reference of 1..256 bytes (for example the child's completed outcome reference); `decided_by` `nil` or the deciding principal's ID.
- **States:** `open → running → offered → accepted | rejected`; from `open`, `running` or `offered` to `cancel_requested`, `cancelled` or `abandoned`; from `cancel_requested` to `cancelled` or `abandoned`. `accepted`, `rejected`, `cancelled` and `abandoned` are final.
- `create(items, tenant, item)` with `item` exactly `%{item_id, parent_run_id, child_run_id, owner, intent, acceptance, parent_close}` stores it `open` at revision 1. Idempotent by `(tenant, item_id)`: equal canonical bytes `{:ok, :duplicate}`, other bytes `:conflict`. A `child_run_id` of another item is `:conflict`, so a new child Run is a new item.
- `get(items, tenant, item_id)` returns `{:ok, item}` or `{:error, :unknown_item}`.
- `start(items, tenant, item_id, %{revision})`: `open → running`.
- `offer(items, tenant, item_id, %{revision, child_run_id, evidence})`: `running → offered`, accepted only from the assigned `child_run_id`.
- `decide(items, tenant, item_id, %{revision, decided_by, decision: :accepted | :rejected})`: `offered → accepted | rejected`, accepted only when `decided_by` is the item's `owner`.
- `close(items, tenant, item_id, %{revision, to: :cancel_requested | :cancelled | :abandoned})`: the closing transitions above. The host maps the parent-close actions of `workflow/delegation` onto them: `:abandon` to `abandoned`, `:request_cancel` to `cancel_requested` (then `cancelled` or `abandoned` when the child ends), `:cancel` to `cancelled`.
- `list_open(items, tenant, %{parent_run_id, after, limit})` returns `{:ok, %{items: items, more: boolean}}`: the non-final items of one parent Run in `item_id` order by bytes, after the `item_id` `after` (`nil` from the start), `limit` 1..256. So after a crash the host finds a parent's open children and their rules, and applies `on_parent_close/1` of `workflow/delegation`.

A transition returns `{:ok, %{revision: new_revision}}`, or `{:ok, :unchanged}` (below).

Fields. `tenant`, `item_id`, `owner` and `decided_by`: 1..128 bytes of valid UTF-8 without a C0 or C1 control character; `parent_run_id` and `child_run_id`: 1..200 bytes of valid UTF-8 without NUL (the `workflow/run` rule); `revision`: 1..2^31−1. Compared by exact bytes.

Errors are `{:error, reason}` with a fixed value that never echoes an ID or the intent: `:invalid`, `:in_transaction`, `:isolation`, `:unknown_item`, `:conflict`, `:stale_revision`, `:not_assignee`, `:not_owner`, `{:state, state}` (the transition is not allowed from the item's current state, which it names, for example `{:state, :abandoned}`), `:unavailable`.

## Rules

Every write checks shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`), before any query; then one transaction through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`, whose first query reads `current_setting('transaction_isolation')` and refuses anything but `read committed` as `:isolation`, before any write. `get/3` and `list_open/3` check shape, then `:in_transaction`, then read under the tenant scope with no isolation check. Every statement runs with `log: false`. A refusal commits nothing. A database failure is `{:error, :unavailable}` and says nothing about whether a write committed; a retry with the same request is safe.

A transition reads the item in its transaction and checks, in this order:

1. No such item: `:unknown_item`.
2. **No-op:** the item is already in the transition's target state with equal facts (the same `child_run_id` and `evidence` for an offer, the same decision and `decided_by` for a decision, the same `to` for a close, `running` for a start): `{:ok, :unchanged}`, and nothing is written (RC-11's "no-op writes nothing"), whatever the revision, so a retry after a lost reply is safe.
3. `offer/4` from another `child_run_id`: `:not_assignee` (a stale holder); `decide/4` by another principal: `:not_owner`.
4. The transition is not allowed from the current state: `{:state, state}`. An offer to an item in a final state or in `cancel_requested` is refused with that state; an offer of other evidence to an `offered` item is `:conflict`.
5. The expected revision is not the item's: `:stale_revision`.
6. Write the new state, the facts and `revision + 1` with one `UPDATE ... WHERE tenant = ... AND item_id = ... AND revision = expected`; zero rows is `:stale_revision`. Under READ COMMITTED a second writer of the same revision waits for the first and then updates no row, so two concurrent decisions commit one.

Cancelling an Attempt of the child changes no item: the item keeps its intent; only `close/4` changes its state. A Run result is evidence only through `offer/4`; no function completes an item without `decide/4`.

The README states the minimum grants for the application role: `USAGE` on `prefix`, `SELECT, INSERT, UPDATE` on the table, no `DELETE`, and the PUBLIC defaults that the floor needs (`CONNECT` and `TEMP` on the database, `EXECUTE` on `elzoo_tenant_id()`). `piece.json` declares telemetry and control `not_applicable`, the config of the items value and the fixed bounds, and the dependencies `state/tenant-isolation` and `workflow/untrusted-content`. The README replaces the catalogue's RC-11 text with this Contract and says what of RC-11 is kept open.

## Kept open (owner's "no corner" rule)

Each option below can be added in place before the first release without breaking a caller: the acceptance, parent-close, state, decision and error sets may gain members, and the item, request and result maps may gain optional keys that the canonical comparison encodes only when present.

- *Acceptance by a person* with an approval of the item digest: a new `acceptance` member (Q4 A).
- *Dependencies between items* (`workflow/dependency-graph`, RC-11's ELZ-026): optional item keys.
- *Completion bound to a lease* (ELZ-028): an optional request key.
- *An assignee that is a person:* a new assignee form beside `child_run_id`.
- *Acceptance criteria as a schema* checked by `core/payload-schema`: an optional item key.
- *A delete of an item's intent* (see the limits); *`assembly/task-workflow`* (RC-37) over it.

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 (`ELZOO_TEST_DATABASE_URL`) with a `DBConnection.ConnectionPool` Repo, not the Sandbox, in random schemas dropped afterwards.

1. RC-11's list for this narrowing: a stale holder cannot offer (`:not_assignee`); a duplicate offer is `:unchanged`, also with a stale revision; a no-op writes nothing (the row's `revision` and `xmin` are unchanged, read inside `Elzoo.TenantIsolation.transact/3` with the tenant's scope); a cancelled child Attempt leaves the item and its intent unchanged.
2. The lifecycle: create, start, offer, accept; and offer, reject; each transition that the state set does not allow is refused with the current state, including an offer after `abandoned` and after `cancel_requested`; each of the three parent-close mappings; a decision by another principal is `:not_owner`; an offer of other evidence is `:conflict`.
3. Two concurrent decisions behind a barrier (another connection holds the item's row lock with `SELECT ... FOR UPDATE` until both `UPDATE`s wait on it, seen in `pg_locks`): one commits and the other is `:stale_revision`, also for an accept against a reject.
4. `create/3` duplicate and conflict, and a second item for the same `child_run_id` is `:conflict`.
5. `list_open/3` after a crash (a new Repo and connection after the writer's process ends) returns the open items of one parent with their parent-close rules and no item of another parent; paging at `limit` 1 and 256 with `more`; a final item is not listed.
6. The intent survives a round trip: the returned neutral map equals `Elzoo.UntrustedContent.encode/1` of the stored value, for `"untrusted"` and `"derived"` content; content of 0 and 4,097 bytes is `:invalid`, of 1 and 4,096 accepted.
7. Row security as `elzoo_app` (ELZ-285: `SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection, only the README grants on the random schema; the test fails, not skips, when the variable is unset): `verify/1` passes; under T1 a T2 item is `:unknown_item` and absent from `list_open/3`; a direct SQL insert of a T2 row fails with SQLSTATE 42501; `DELETE` fails with 42501; every function succeeds with only the README grants.
8. A caller's open transaction gives `:in_transaction` for every function before any query; a Repo whose connections default to `repeatable read` gets `:isolation` from every write with nothing committed.
9. Bounds at their edges: each ID at 0, 1, its maximum and one over, invalid UTF-8, a NUL, and a C0 and C1 character where the rule forbids them; `evidence` at 256 and 257 bytes; a revision of 0 and 2^31; an unknown acceptance, parent-close, decision or `to` value.
10. Negative controls, one at a time, each restored before the final gates: drop the revision check from the `UPDATE` (case 3 commits both decisions); skip the assignee check (case 1's stale holder offers); make a no-op write (case 1's `xmin` changes).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide ("Reviewer by risk": it finds the code and a test for each rule above), the exact-head hosted check and the merge queue are required. Record in the pull request body the change in the time of the aggregate consumer of `test/export_test.exs` (#814, #819).

## Limits to state

The `state/tenant-isolation` limits apply. READ COMMITTED is a consumer Need that the Piece checks but cannot set. `owner`, `decided_by`, the assignee and the evidence reference are host-vouched; the Piece checks that a decision names the owner, not who the caller is. Evidence is a reference, not the result, and acceptance is the parent's decision, not a check of the result. Intents hold people's text and have no delete or erasure in Wave 8 (dead tuples, WAL and backups keep content until PostgreSQL reclaims them). No dependencies between items, lease, person assignee or acceptance by a person.
