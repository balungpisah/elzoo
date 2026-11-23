# delivery/durable-mailbox

Durable mail to an address, and the **continuation chain** of the address's Runs. One durable
Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16; its
three tables are protected by the `state/tenant-isolation` floor.

- Only declared mail is written: a message whose name the binding's declaration does not list,
  or whose payload fails the name's `core/payload-schema` schema, leaves no row.
- A chain is one correlation ID (`chain_id`) and an ordered list of links, one Run each. Each
  link names its predecessor and has at most one successor; the live tip receives the mail.
  Mail addressed to any link's `run_id`, live or closed, is mail to the chain.
- Mail is claimed in order, one message at a time, by exactly one link.
- `rollover/3` is one atomic step: it closes the tip and creates exactly one successor, which
  keeps the tip's pin unless the call names an explicit pin change.

The Piece starts no Run, calls no engine, and has no clock, process, timer or notifier. The
host composes it with the engine (for example `delivery/room`): the old Run is terminal before
`rollover/3`, and the host starts the successor after it from what it recorded.

## Copy and providers

Select `delivery/durable-mailbox` with `mix elzoo.take`; the dependency-closed copy is owned by
the consuming application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation` (the floor, its migration helper, `transact/3` and `verify/3`) and
`core/payload-schema` (`build/2` and `check/3`). No Cure source of its own; the copy includes
the Cure source of `core/port`, a dependency of `core/payload-schema`. Providers: `ecto_sql` 3.14.0 and
`postgrex` 0.22.4, `jason` 1.4.5 (the canonical encoding), `elixir`, `otp` (`:crypto` SHA-256);
the tests also use `telemetry`. Exact versions and claim-level grounding are in
[piece.json](piece.json).

## Migration

Call `Elzoo.DurableMailbox.Migration.install(prefix)` from the `up/0` of a consumer Ecto
migration, run by the table owner, in an existing schema `prefix`. It installs the
tenant-isolation readers in `prefix` (`CREATE OR REPLACE`), creates three tables and protects
each with `Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`,
`space_column: nil`):

- `elzoo_mailbox_chains`: `PRIMARY KEY (tenant, chain_id)`, the declaration identity
  (`declaration_id`, `declaration_version`, `declaration_sha256`), the tip's sequence
  `tip_seq` and the next message sequence `next_message_seq`.
- `elzoo_mailbox_links`: `PRIMARY KEY (tenant, chain_id, seq)`,
  `UNIQUE (tenant, chain_id, predecessor_seq)`, `UNIQUE (tenant, run_id)` and
  `UNIQUE (tenant, unit_identity)`, and the link fields below (`carry` as canonical JSON text).
- `elzoo_mailbox_messages`: `PRIMARY KEY (tenant, chain_id, message_id)`,
  `UNIQUE (tenant, chain_id, seq)`, the sender, name, schema version, `payload` as canonical
  JSON text, the state, the link it is delivering to or was settled by, and the refusal
  reason. A partial index on `(tenant, chain_id, seq)` over the pending and delivering
  messages finds the oldest pending message and counts the open ones.

`prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the
fixed message `"invalid durable mailbox prefix"` before any DDL is queued. Nothing is reversible
by the Piece; a `down/0` is the consumer's.

### Grants

The application role needs exactly these, and nothing else:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_mailbox_chains TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_mailbox_links TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_mailbox_messages TO app_role;
```

No `DELETE`: the application role cannot remove a chain, a link or a message (SQLSTATE 42501).
The floor also needs the PUBLIC defaults: `CONNECT` and `TEMP` on the database (`verify/1`
rebuilds the floor on a temporary table) and `EXECUTE` on `prefix.elzoo_tenant_id()`. Connect
the application as a non-owner role that does not bypass row security, and call `verify/1`,
connected as that role, before serving.

## Interface

```elixir
{:ok, mailbox} =
  Elzoo.DurableMailbox.new([repo: MyApp.Repo, prefix: "rooms"], %{
    id: "room.mail",
    version: 1,
    max_pending: 256,
    messages: %{
      "chat.post" => %{schema_version: 1, schema: %{"type" => "object", "required" => ["text"]}}
    }
  })

:ok = Elzoo.DurableMailbox.verify(mailbox)

Elzoo.DurableMailbox.open(mailbox, "tenant-1", %{
  chain_id: "room-7", run_id: "room-7/run-1", unit_identity: "room-7/unit-1",
  pin: "recipe-package-v1:sha256:...", carry: %{"members" => []}
})
#=> {:ok, :applied}

Elzoo.DurableMailbox.put(mailbox, "tenant-1", %{
  sender: %{kind: :human, id: "user-3"},
  address: {:chain, "room-7"},
  message: %{message_id: "m-1", name: "chat.post", schema_version: 1, payload: %{"text" => "hi"}}
})
#=> {:ok, :applied}
```

Every function takes the binding, the tenant and one request map, except `new/2` and
`verify/1`. Request maps have exactly the keys listed.

- `new(opts, declaration)`: `opts` is exactly `repo:` (a started Ecto Repo module) and `prefix:`.
  The **declaration** is exactly `%{id, version, max_pending, messages}`: `id` 1..128 bytes of
  `[a-z0-9._-]`, `version` 1..2^31−1, `max_pending` 1..65,536 (no default), `messages` a map of
  1..64 names (each 1..128 bytes of `[a-z0-9._-]`) to exactly
  `%{schema_version: 1..2^31−1, schema: decoded_json_schema}`. Each schema is built here with
  `Elzoo.PayloadSchema.build(%{"id" => name, "direction" => "input", "schema_id" => name,
  "schema_version" => schema_version}, schema)`. `{:ok, mailbox}`, or
  `{:error, :invalid_declaration}` when anything fails, including a schema that does not build.
- `verify(mailbox)`: `Elzoo.TenantIsolation.verify/3` for the chains, links and messages tables
  in that order; `:ok` or `{:error, {table, reason}}` for the first failing one (`table` is
  `:chains`, `:links` or `:messages`, `reason` one of `verify/3`'s). No `:in_transaction`
  check: it also runs inside a caller's transaction, with the same result. A first argument that
  is not a mailbox from `new/2` raises `FunctionClauseError`, and an identifier that
  `verify/3` refuses raises its `ArgumentError`; neither is an error tuple.
- `open(mailbox, tenant, %{chain_id, run_id, unit_identity, pin, carry})`: creates the chain
  with the binding's declaration identity and its first link (`seq` 1, `carry_kind: :opened`,
  `state: :live`). `{:ok, :applied}`; `{:ok, :duplicate}` for an equal request under the same
  declaration identity; `{:error, :conflict}` for another request, or the same request from a
  binding with another declaration; `{:error, :identity_in_use}` when a link of the tenant
  holds the `run_id` or the `unit_identity` (after the duplicate check).
- `put(mailbox, tenant, %{sender, address, message})`: `sender` is the host-vouched
  `%{kind: :human | :service | :agent, id}`; `address` is `{:chain, chain_id}` or
  `{:run, run_id}`; `message` is `%{message_id, name, schema_version, payload}`.
  `{:ok, :applied}` or `{:ok, :duplicate}`; the checks are under "Rules".
- `claim(mailbox, tenant, %{chain_id})`: `{:ok, %{message: message, link_seq, run_id,
  unit_identity}}` with the live tip's facts, `{:ok, :empty}` when no message is pending, or
  `{:ok, :stopped}` when the tip is stopped (nothing is claimed). `message` is
  `%{message_id, sender, name, schema_version, payload, seq}`.
- `settle(mailbox, tenant, %{chain_id, message_id, link_seq, result})`: `result` is `:applied`
  (the engine replied applied or duplicate), `:not_applied` (the host's own reading of the
  engine record shows the input absent while that Run is terminal or fenced) or
  `{:refused, reason}` (the input was not given, or is not shown to have been given, to a
  pattern), `reason` one of `:record_size`, `:unacknowledged`, `:invalid_input` and
  `:input_id_conflict`. `{:ok, :applied}`, `{:ok, :duplicate}` or `{:error, :not_delivering}`.
- `plan_rollover(mailbox, tenant, %{chain_id, link_seq, change})`: `change` is `nil` or
  `%{pin, ref}` (`ref` 1..256 bytes, the host's authorised, recorded action). Records on the
  live tip `planned_pin`: the tip's `pin` when `change` is `nil`, else `change.pin`.
  `{:ok, %{planned_pin: pin, previous: earlier_planned_pin_or_nil}}`, so a caller that plans
  another version knows the pin record it must remove.
- `rollover(mailbox, tenant, %{chain_id, link_seq, outcome, successor, change})`: `outcome` is
  the host-vouched terminal outcome code of the link's Run (1..64 bytes of `[a-z0-9_]`),
  `successor` is `%{run_id, unit_identity, carry, carry_kind: :finished | :restarted}`,
  `change` as for `plan_rollover/3`. `{:ok, %{seq: successor_seq}}`.
- `chain(mailbox, tenant, %{chain_id, after_seq, limit})`: `after_seq` `nil` or a sequence,
  `limit` 1..256. `{:ok, %{declaration: {id, version, sha256}, links: links, more: boolean,
  tip: tip}}`: the links with `after_seq < seq <= after_seq + limit`, oldest first, without
  their `carry`; `more` when the chain has links after the page; the tip link with its `carry`,
  read in the same statement.
- `status(mailbox, tenant, %{chain_id, message_id})`: `{:ok, %{state: :pending | :delivering |
  :consumed | :refused, link_seq, reason}}`, `link_seq` the link it is delivering to or was
  settled by (`nil` while pending) and `reason` the refusal reason (else `nil`), or
  `{:error, :unknown_message}`. A host that posted mail through an Effect and got an unknown
  outcome reads here whether it was written.

A **link** is `%{seq, run_id, unit_identity, predecessor_seq, pin, planned_pin, carry,
carry_kind, state, outcome, change_ref, stopped}`: `seq` from 1 in the chain; `predecessor_seq`
`nil` for the first link, else `seq − 1`; `pin` the opaque recipe identity of the link's Run;
`planned_pin` `nil` or the pin its successor will have; `carry` the JSON term the link's Run
starts with, kept for every link (`chain/3` returns it for the tip); `carry_kind` `:opened`,
`:finished` or `:restarted`; `state` `:live` (the tip) or `:closed`; `outcome` `nil` while live;
`change_ref` `nil` or the `ref` of the explicit pin change that made this link; `stopped`
`false` until a `{:refused, :record_size}` settle.

### Fields

| Field | Rule |
| --- | --- |
| `tenant`, `chain_id`, `run_id`, `pin`, a sender `id` | 1..128 bytes of valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F), compared by exact bytes |
| `message_id` | 1..155 bytes under the same rule, so a room's engine input ID `mail:<message_id>` stays within 160 bytes |
| `unit_identity` | 1..160 bytes of valid UTF-8 without NUL |
| `change.ref` | 1..256 bytes under the text rule |
| `outcome` | 1..64 bytes of `[a-z0-9_]` |
| `link_seq`, `after_seq` | an integer 1..2^31−1 |
| `carry`, `payload` | a JSON term of at most 65,536 bytes of canonical JSON |

A **JSON term** is `nil`, a boolean, an integer, a float, a valid UTF-8 binary, a proper list
or a non-struct map with valid UTF-8 binary keys of such terms, with at most 32 nested lists
and maps. Anything else, and a request with another shape, is `{:error, :invalid}`.

### Canonical JSON

The **canonical JSON** of a term is its compact Jason 1.4.5 encoding (`Jason.encode!/1`,
default options) with the keys of every object sorted by their bytes: no whitespace; strings
as UTF-8 with `"` and `\` escaped, U+0000–U+001F escaped (`\b`, `\t`, `\n`, `\f`, `\r`, else
`\u00XX` with uppercase hex) and nothing else escaped; integers in decimal; floats in the
shortest form that reads back as the same float (`:erlang.float_to_binary(f, [:short])`, for
example `1.0`), so `1` and `1.0` differ. It decides every equal-bytes comparison, the
65,536-byte bounds, and what `carry` and `payload` are stored as; `claim/3` and `chain/3`
decode them with OTP's `:json` (`null` as `nil`), which keeps integers of any length: Jason
1.4.5's decoder refuses an integer of more than 1,024 digits.

The **declaration identity** is `{id, version, sha256}`, `sha256` the lowercase hex SHA-256 of
the canonical JSON of

```json
{"id": id, "max_pending": max_pending, "version": version,
 "messages": {name: {"schema": schema, "schema_version": schema_version}, ...}}
```

so two declarations that differ in anything, including `max_pending` or one schema, have
different identities.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or a payload:
`:invalid_declaration` (only from `new/2`), `:invalid`, `:in_transaction`, `:isolation`,
`:undeclared_name`, `:schema_version`, `:invalid_payload`, `:unknown_chain`,
`:declaration_mismatch`, `:conflict`, `:mailbox_full`, `:identity_in_use`, `:unknown_link`,
`:not_delivering`, `:not_tip`, `:delivery_unsettled`, `:already_rolled_over`, `:plan_mismatch`,
`:unknown_message`, `:unavailable`. The address, sender-kind, refusal-reason, settle-result and
error sets, and the request, link, message and result maps, may gain members and optional keys
in a later in-place version (an optional key is encoded in a comparison only when present);
match on the members and keys you use.

## Rules

Every write (`open/3`, `put/3`, `claim/3`, `settle/3`, `plan_rollover/3`, `rollover/3`) checks
the request's shape and bounds (`:invalid`), then `repo.in_transaction?()`
(`:in_transaction`), both before any query; then it runs one transaction through
`Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`, whose first query reads
`current_setting('transaction_isolation')` and refuses anything but `read committed` as
`:isolation`, before any write. `chain/3` and `status/3` check shape, then `:in_transaction`,
then read in one statement under the tenant scope with no isolation check. Every statement
runs with `log: false`. A refusal commits nothing. A database failure is
`{:error, :unavailable}` and says nothing about whether a write committed; a retry with the
same request is safe.

**The chain row lock.** Every write after `open/3` takes the chain row with
`SELECT ... FOR UPDATE` before it reads or writes a link or a message of that chain, so the
writes of one chain run one after the other. The one read before it is the resolution of a
`{:run, run_id}` address in `put/3`: links are never deleted and a `run_id` names one link of a
tenant, so the chain it names cannot change.

`open/3` inserts the chain with `ON CONFLICT DO NOTHING`; two concurrent opens of one
`chain_id` create one chain, and the other waits on the key and then returns `:duplicate` or
`:conflict` by its bytes (the declaration identity, `run_id`, `unit_identity`, `pin` and the
canonical `carry`). The first link is inserted the same way, so a `run_id` or `unit_identity`
that a link of the tenant holds is `:identity_in_use` and the chain is not kept.

`put/3` checks, in this order, and stops at the first failure, before any write:

1. Shape and bounds (`:invalid`).
2. `name` is not a key of the binding's declaration: `:undeclared_name`.
3. `schema_version` is not the declared version of that name: `:schema_version`.
4. `PayloadSchema.check/3` of the payload against the name's built schema is not `:ok`:
   `:invalid_payload` (every refusal of that check; its violations are not echoed).
5. `:in_transaction`, then the isolation check (steps 1–4 run no query).
6. The address resolves to no chain of the tenant: `:unknown_chain`.
7. The binding's declaration identity is not the chain's: `:declaration_mismatch`.
8. A message of `(tenant, chain_id, message_id)` exists: with equal bytes of the sender kind
   and ID, name, schema version and canonical payload it is `{:ok, :duplicate}` and changes
   nothing; otherwise `:conflict`. The address is not compared, so the same mail put once to
   the chain and once to a closed link's `run_id` is a duplicate.
9. The chain holds `max_pending` messages that are pending or delivering: `:mailbox_full`,
   with no eviction.
10. Insert the message as pending with the chain's next message sequence.

`claim/3`, under the chain row lock: when a message is delivering it returns that message
again (it is delivering to the live tip, because `rollover/3` refuses a link with a delivering
message); else when the tip is stopped it returns `{:ok, :stopped}`; else it marks the pending
message with the lowest sequence delivering to the tip and returns it; else `{:ok, :empty}`. So
a message is claimed by exactly one link, and a host that crashes after `claim/3` and before the
engine call gets the same message for the same link at its next claim.

`settle/3`, under the chain row lock: a settle that repeats the recorded final result of that
message for that link (`:applied`, or `{:refused, reason}` with the same reason) is
`{:ok, :duplicate}`; otherwise the message must be delivering to `link_seq`, else
`:not_delivering` (also for an absent message, and for a repeated `:not_applied`, after which
the message is pending again). `:applied` marks it consumed by that link; `:not_applied` returns
it to pending with its sequence, so it is the oldest pending message again;
`{:refused, reason}` marks it refused with the reason, a final state that `status/3` shows and
that is never claimed again. `{:refused, :record_size}` also sets `stopped: true` on the link it
was delivered to, in the same transaction; a later rollover gives a successor that is not
stopped.

`plan_rollover/3`, under the chain row lock: `:unknown_link` for a link the chain lacks,
`:not_tip` unless the link is the live tip; otherwise it replaces `planned_pin`. A plan may be
replaced until `rollover/3`.

`rollover/3`, one transaction under the chain row lock:

1. `:unknown_link` for a link the chain lacks.
2. When the named link is closed: a recorded successor with equal bytes of `outcome`,
   `successor` (`run_id`, `unit_identity`, canonical `carry`, `carry_kind`) and `change`
   returns `{:ok, %{seq: that_successor}}` again; otherwise `:already_rolled_over`.
3. A message delivering to the link: `:delivery_unsettled`. A refused message does not block.
4. The successor's pin is the link's `pin`, or `change.pin` when `change` is set; no
   `planned_pin`, or one that differs from it, is `:plan_mismatch`.
5. A successor `run_id` or `unit_identity` that a link of the tenant already holds:
   `:identity_in_use`.
6. Mark the link closed with `outcome` (one `UPDATE`), insert exactly one successor link
   (`seq + 1`, `predecessor_seq` the link's `seq`, the given carry and `carry_kind`,
   `change_ref` `change.ref` or `nil`, `stopped: false`, `planned_pin: nil`), and make it the
   tip.

The primary key on `(tenant, chain_id, seq)` and the unique index on
`(tenant, chain_id, predecessor_seq)` refuse a second successor row; the chain row lock makes a
second rollover read the closed link and get step 2's answer. The Piece maps no unique
violation of `rollover/3` to a result: it is `:unavailable`.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them.
- READ COMMITTED is a consumer Need that the Piece checks but cannot set.
- The sender, the terminal outcome, the change reference and the `:not_applied` and refused
  readings are host-vouched; the Piece does not check them against an engine record.
- A message is delivered to exactly one link, not exactly once end to end: the engine's input
  IDs decide what a Run saw.
- Mail payloads hold people's text and have no delete, expiry or erasure: dead tuples, WAL and
  backups keep content until PostgreSQL reclaims them. Consumed and refused messages stay.
- Links are never pruned, so a chain grows by one row per rollover.
- The `UPDATE` grant lets code that runs its own SQL as the application role rewrite a row of
  its tenant without these rules; only calls through this Piece keep them.
- The Repo must be a started Ecto Repo: an unstarted Repo or another module raises from
  `in_transaction?/0` instead of returning an error atom. A stored state, kind or reason that
  the running copy does not know (a row written outside the Piece) raises at read.
- The Piece emits no telemetry and no log, and its queries pass `log: false`; the consumer
  Repo's query telemetry still receives their parameters (tenant, IDs, payloads and carries),
  and a Repo that logs queries still logs the `begin` and `commit` of each transaction.
- Two concurrent rollovers of different chains of one tenant that name the same successor
  `run_id` or `unit_identity` can both pass step 5; the later one then fails on the unique
  index as `:unavailable`, and its retry is `:identity_in_use`.
- No Run start, engine call, timer, notifier, priority, expiry or dead-lettering; each is a
  later in-place addition.

## Evidence

[test/elzoo/durable_mailbox_test.exs](test/elzoo/durable_mailbox_test.exs) runs on the worker's
own disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) with
`DBConnection.ConnectionPool` Repos, not the Sandbox, in random schemas dropped afterwards.
Every Piece call runs as the ELZ-285 application role (`SET ROLE` to `ELZOO_TEST_APP_ROLE` on
every connection) with only the grants above; the tests fail, not skip, without that variable.
The races hold the chain row (or a table lock) in another connection until each call is seen
waiting in `pg_locks`. Finite scenarios, not proofs.
