# workflow/work-item

The durable record of one item that a parent Run delegated to one child Run: its stable intent,
the child Run it is assigned to, its parent-close rule, an explicit lifecycle with a revision,
the child's result offered as evidence, and acceptance or rejection by the parent Run's
principal. A Run result is evidence offered for acceptance, never completion. One durable Piece
in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 19; its table
is protected by the `state/tenant-isolation` floor.

This Piece narrows the catalogue proposal RC-11 ("Work Item has stable intent, acceptance
revision, assignee/authority and explicit lifecycle. A Run result is evidence offered for
acceptance, never automatic business completion") to one item per child Run (ELZ-347). What of
RC-11 stays open is listed under "Kept open".

The Piece calls neither `domain/authorization` nor `workflow/run`. The parent-close values
restate those of `workflow/delegation`, which this Piece does not call.

## Copy and providers

Select `workflow/work-item` with `mix elzoo.take`; the dependency-closed copy is owned by the
consuming application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation` (the floor, its migration helper, `transact/3` and `verify/3`) and
`workflow/untrusted-content` (the marked intent). No Cure source. Providers: `ecto_sql` 3.14.0
and `postgrex` 0.23.0, `elixir`, `otp` (`:crypto` SHA-256); the tests also use `telemetry`.
Exact versions and claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.WorkItem.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration,
run by the table owner, in an existing schema `prefix`. It installs the tenant-isolation readers
in `prefix` (`CREATE OR REPLACE`), creates `elzoo_work_items` with `PRIMARY KEY (tenant,
item_id)`, `UNIQUE (tenant, child_run_id)` and a partial index on `(tenant, parent_run_id,
item_id)` for the non-final items, and protects it with
`Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`, `space_column: nil`).
IDs are `text COLLATE "C"`; the intent's content and the evidence are `bytea`. `prefix` must
match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the fixed message
`"invalid work item repo or prefix"` before any DDL is queued. Nothing is reversible by the
Piece; a `down/0` is the consumer's.

### Grants

The application role needs exactly these, and nothing else:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_work_items TO app_role;
```

plus the PUBLIC defaults that the floor needs: `CONNECT` and `TEMP` on the database
(`Elzoo.TenantIsolation.verify/3` needs `TEMP` for its rebuild) and `EXECUTE` on the
`state/tenant-isolation` reader `prefix.elzoo_tenant_id()`. With no `DELETE` grant an item
cannot be removed (SQLSTATE 42501). Connect the application as a non-owner role that does not
bypass row security, and call `verify/1` at startup.

## Interface

```elixir
items = Elzoo.WorkItem.new(repo: MyApp.Repo, prefix: "work")

Elzoo.WorkItem.create(items, "tenant-1", %{
  item_id: "item-7",
  parent_run_id: "run-1",
  child_run_id: "run-1/child-7",
  owner: "agent-1",
  intent: marked,
  acceptance: :parent,
  parent_close: :request_cancel
})
#=> {:ok, :applied}

Elzoo.WorkItem.start(items, "tenant-1", "item-7", %{revision: 1})
#=> {:ok, %{revision: 2}}
Elzoo.WorkItem.offer(items, "tenant-1", "item-7",
  %{revision: 2, child_run_id: "run-1/child-7", evidence: "outcome:run-1/child-7"})
#=> {:ok, %{revision: 3}}
Elzoo.WorkItem.decide(items, "tenant-1", "item-7",
  %{revision: 3, decided_by: "agent-1", decision: :accepted})
#=> {:ok, %{revision: 4}}
```

- `new(opts)` takes exactly `repo:` (a started Ecto Repo module) and `prefix:` and returns an
  items value, or raises the fixed `ArgumentError`.
- `verify(items)` runs `Elzoo.TenantIsolation.verify/3` for the table and returns its result.
  It has no `:in_transaction` check: `verify/3` also runs inside a caller's transaction.
- `create(items, tenant, item)`, `item` exactly `%{item_id, parent_run_id, child_run_id,
  owner, intent, acceptance, parent_close}`, stores it `open` at revision 1: `{:ok, :applied}`;
  `{:ok, :duplicate}` when `item_id` is stored with equal canonical bytes (also after later
  transitions); `{:error, :conflict}` for other bytes, or for a `child_run_id` of another item.
  A new child Run is a new item.
- `get(items, tenant, item_id)`: `{:ok, item}` or `{:error, :unknown_item}`.
- `start(items, tenant, item_id, %{revision})`: `open → running`.
- `offer(items, tenant, item_id, %{revision, child_run_id, evidence})`: `running → offered`,
  only from the assigned `child_run_id`.
- `decide(items, tenant, item_id, %{revision, decided_by, decision})`, `decision` `:accepted`
  or `:rejected`: `offered → accepted | rejected`, only when `decided_by` is the item's
  `owner`.
- `close(items, tenant, item_id, %{revision, to})`, `to` `:cancel_requested`, `:cancelled` or
  `:abandoned`: the closing transitions below.
- `list_open(items, tenant, %{parent_run_id, after, limit})`: `{:ok, %{items: items, more:
  boolean}}`, the non-final items of one parent Run in `item_id` order by bytes, after the
  `item_id` `after` (`nil` from the start), at most `limit` (1..256); `more` tells whether
  another follows. After a crash the host finds a parent's open children and their rules with
  it, and applies `on_parent_close/1` of `workflow/delegation`.

A transition returns `{:ok, %{revision: new_revision}}`, or `{:ok, :unchanged}` for a no-op.

An **item** is `%{item_id, parent_run_id, child_run_id, owner, intent, acceptance,
parent_close, state, revision, evidence, decided_by}`: `owner` is the ID of the parent Run's
principal (host-vouched); `intent` is the stored marked value's neutral map
(`Elzoo.UntrustedContent.encode/1`: schema, trust class, sources, bound and content);
`acceptance` is `:parent`, the one member of a closed set in this version; `parent_close` is
`:abandon`, `:request_cancel` or `:cancel`; `revision` counts from 1; `evidence` is `nil` or the
offered reference; `decided_by` is `nil` or the deciding principal's ID.

### States

```text
open → running → offered → accepted | rejected
open | running | offered → cancel_requested | cancelled | abandoned
cancel_requested → cancelled | abandoned
```

`accepted`, `rejected`, `cancelled` and `abandoned` are final. The host maps the parent-close
actions of `workflow/delegation` onto `close/4`: `:abandon` to `abandoned`, `:request_cancel` to
`cancel_requested` (then `cancelled` or `abandoned` when the child ends), `:cancel` to
`cancelled`.

### Fields

| Field | Rule |
| --- | --- |
| `tenant`, `item_id`, `owner`, `decided_by`, `after` | 1..128 bytes of valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F) |
| `parent_run_id`, `child_run_id` | 1..200 bytes of valid UTF-8 without NUL (the `workflow/run` rule) |
| `intent` | a `workflow/untrusted-content` marked value whose content has 1..4,096 bytes, stored whole |
| `evidence` | an opaque binary of 1..256 bytes (any bytes; for example the child's completed outcome reference) |
| `revision` | an integer 1..2^31−1 |
| `limit` | an integer 1..256 |

IDs are compared by exact bytes. Errors are `{:error, reason}` with a fixed value that never
echoes an ID or the intent: `:invalid`, `:in_transaction`, `:isolation`, `:unknown_item`,
`:conflict`, `:stale_revision`, `:not_assignee`, `:not_owner`, `{:state, state}` (the
transition is not allowed from the item's current state, which it names, for example
`{:state, :abandoned}`), `:unavailable`.

## Rules

Every write checks shape and bounds (`:invalid`), then `repo.in_transaction?()`
(`:in_transaction`), both before any query; then one transaction through
`Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`, whose first query reads
`current_setting('transaction_isolation')` and refuses anything but `read committed` as
`:isolation`, before any write. READ COMMITTED is a consumer Need that the Piece checks but
cannot set. `get/3` and `list_open/3` check shape, then `:in_transaction`, then read under the
tenant scope with no isolation check. Every statement runs with `log: false`. A refusal commits
nothing.

`create/3` inserts with `ON CONFLICT DO NOTHING`, which covers both keys; a concurrent insert of
the same key waits for the first. When nothing was inserted, the stored digest of that
`item_id` decides `:duplicate` or `:conflict`; no row for that `item_id` means another item
holds the `child_run_id` (`:conflict`).

A transition reads the item in its transaction and checks, in this order:

1. No such item: `:unknown_item`.
2. **No-op:** the item is already in the transition's target state with equal facts (`running`
   for a start; the same `child_run_id` and `evidence` for an offer; the same decision and
   `decided_by` for a decision; the same `to` for a close): `{:ok, :unchanged}`, whatever the
   revision, and nothing is written. A retry after a lost reply is safe.
3. `offer/4` from another `child_run_id`: `:not_assignee` (a stale holder); `decide/4` by
   another principal: `:not_owner`.
4. The transition is not allowed from the current state: `{:state, state}`. An offer to a final
   or `cancel_requested` item names that state; an offer of other evidence to an `offered` item
   is `:conflict`.
5. The expected revision is not the item's: `:stale_revision`.
6. One `UPDATE ... WHERE tenant = ... AND item_id = ... AND revision = expected` writes the new
   state, the facts and `revision + 1`; zero rows is `:stale_revision`. Under READ COMMITTED a
   second writer of the same revision waits for the first and then updates no row, so of two
   concurrent decisions one commits and the other is `:stale_revision` (a retry of it then
   gives `:unchanged` or the winner's state).

Cancelling an Attempt of the child changes no item: the Piece has no Attempt input, the item
keeps its intent, and only `close/4` changes its state. A Run result is evidence only through
`offer/4`; no function completes an item without `decide/4`.

### Canonical bytes

`create/3` stores a SHA-256 digest of the item's canonical bytes and compares digests. The
bytes are `"elzoo.work-item.item" <> <<0>>` followed by each item field, sorted by its name, as
`<<byte_size(name)::32, name::binary, byte_size(value)::32, value::binary>>` (each length a
32-bit unsigned big-endian integer; the name is the map key as text). Values: text as its
bytes; an atom as its name; `intent` as the same framing of each key of its neutral map, sorted,
with integers as ASCII decimal and `sources` as the framing of each source in order. The tenant
is not encoded: it is part of the key. A key that a later in-place version adds as optional is
encoded only when present, so existing digests and the duplicates they decide stay equal.

## Kept open

Each option can be added in place before the first release without breaking a caller: the
acceptance, parent-close, state, decision and error sets may gain members, and the item,
request and result maps may gain optional keys that the canonical bytes encode only when
present. Match on the members and keys you use.

- Acceptance by a person with an approval of the item digest: a new `acceptance` member.
- Dependencies between items (`workflow/dependency-graph`, RC-11's ELZ-026, and RC-11's
  "dependency failure policy explicit"): optional item keys.
- Completion bound to a lease (RC-11's ELZ-028): an optional request key.
- An assignee that is a person: a new assignee form beside `child_run_id`.
- Acceptance criteria as a schema checked by `core/payload-schema`: an optional item key.
- A delete of an item's intent (see the limits); `assembly/task-workflow` (RC-37) over this
  Piece.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them.
- `owner`, `decided_by`, the assignee and the evidence reference are host-vouched: the Piece
  checks that a decision names the owner and an offer names the assignee, not who the caller
  is.
- Evidence is a reference, not the result, and acceptance is the parent's decision, not a check
  of the result.
- Intents hold people's text and have no delete or erasure in this version: dead tuples, WAL
  and backups keep content until PostgreSQL reclaims them.
- No dependencies between items, lease, person assignee or acceptance by a person.
- The `UPDATE` grant lets code that runs its own SQL as the application role overwrite an
  item's columns; only calls through this Piece keep the lifecycle and revision rules.
- The Repo must be a started Ecto Repo: an unstarted Repo or another module raises from
  `in_transaction?/0` instead of returning an error atom. A stored state or rule that the
  running copy does not know (a row written outside the Piece) raises at read.
- A database failure, including a lost connection during `COMMIT`, is `{:error, :unavailable}`
  and says nothing about whether a write committed; a retry with the same request is safe.
- The Piece emits no telemetry and no log, and its queries pass `log: false`; the consumer
  Repo's query telemetry still receives their parameters (tenant, IDs, intent and evidence).

## Evidence

[test/elzoo/work_item_test.exs](test/elzoo/work_item_test.exs) runs on the worker's own
disposable PostgreSQL 19 database (`ELZOO_TEST_DATABASE_URL`) with
`DBConnection.ConnectionPool` Repos, not the Sandbox, in random schemas dropped afterwards.
Every Piece call runs as the ELZ-285 application role (`SET ROLE` to `ELZOO_TEST_APP_ROLE` on
every connection) with only the grants above; the tests fail, not skip, without that variable.
The scenarios and negative controls are listed in [piece.json](piece.json). Finite scenarios,
not proofs.

## Changes

- ELZ-416 (2026-11-26): the server this Piece states and is tested on moves from
  PostgreSQL 16 to PostgreSQL 19; its tests now require a PostgreSQL 19 server.
  A host on an older server upgrades to PostgreSQL 19 before taking this
  revision. No code or API change: only the module documentation names the new
  server and the README names the current provider pins.
