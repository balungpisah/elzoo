# ELZ-344 — Durable mail for rooms: declared messages only, one claim at a time, and a continuation chain of Runs

- Phase: Wave 8 Level 1
- Dependencies: ELZ-033, ELZ-115, ELZ-270, ELZ-285
- Release: V1B
- Output: new `delivery/durable-mailbox` Piece
- Change class: Piece-only
- Owned paths: `pieces/delivery/durable-mailbox/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `state/tenant-isolation`, `core/payload-schema`, `assembly/run-engine` and `delivery/dead-letter-store`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16: durable mail to an address, accepted only for declared message names whose payload passes the declared schema, and the **continuation chain** of each address: one correlation ID, an ordered list of links (one Run each), each link naming its predecessor, exactly one successor per link, and the live tip that receives the mail. The Contract source is the `delivery/durable-mailbox` section of [the Wave 8 plan](../docs/plans/bot-platform-wave8.md) ("Level 1"), under owner answers Q1 A and Q5 A (2026-11-23; [choices](../docs/choices.md#wave-8-owner-choices-2026-11-23)) and the owner's settled decisions 1 and 3 of 2026-11-21 (the continuation chain with a closed input surface; the inherited pin). The tables are Piece-owned and protected by `state/tenant-isolation` (ELZ-270), the Wave 6 Q1 A precedent of `domain/metering` and `state/memory-record`.

The "one atomic step" of settled decision 1 is `rollover/3` below, one transaction of this Piece: the old Run is terminal before it, and the host starts the successor after it from what it recorded (the owner's reading, recorded with the 2026-11-23 answers). The Piece starts no Run, calls no engine and has no clock, process or timer. `delivery/room` (Wave 8 Level 2) composes it with the engine.

The Piece keeps durable state, serializes concurrent writers, keeps tenant content apart under row security and stores untrusted payloads, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6); the hosted `check-piece` run does not replace the local run.

## Facts on `main` that this task builds on

Checked at `main` `bce5ea99`:

- `Elzoo.PayloadSchema.build(port, schema)` returns `{:ok, checked}` or `{:error, :invalid_port | :invalid_schema}`; `port` is the exact four-key `core/port` map (`"id"`, `"direction"`, `"schema_id"`, `"schema_version"`, nonempty UTF-8 texts and a positive integer). `check(checked, port, payload)` returns `:ok`, `{:error, atom}` (`:invalid_port`, `:port_mismatch`, `:version_mismatch`, `:invalid_payload`, `:too_large`, `:too_deep`, `:validation_failed`) or `{:error, {:violations, list}}`; payloads are JSON terms with string keys, at most 65,536 bytes of compact JSON and depth 32.
- `Elzoo.TenantIsolation.Migration.install/1`, `Migration.protect/2`, `transact/3` and `verify/3` are as `domain/metering` and `state/memory-record` use them: the migration functions issue DDL through `Ecto.Migration.execute/1` inside an Ecto migration; `transact/3` takes `%{tenant: t}` with `t` 1..128 bytes of valid UTF-8 without a C0 or C1 control character, refuses a caller's open transaction (`{:error, {:tenant_isolation, :in_transaction}}`); `verify/3` returns `:ok` or `{:error, reason}` with `:unavailable`, `:bypass_role`, `:not_enabled`, `:not_forced`, `:floor_missing` or `:floor_changed`.
- `assembly/run-engine`: a Unit identity is 1..160 bytes of UTF-8 without NUL, a Run ID at most 200 bytes, an input ID 1..160 bytes; `state/recipe-store` keeps pin records per version and Run ID of 1..128 bytes, and its version identity, which `pin/4` requires, is the 89-byte `recipe-package-v1:sha256:<64 hex>`, the same as a `workflow/version-pin` identity (only its artifact ID is 64 hex characters). So a link's `run_id` here is 1..128 bytes, its `unit_identity` 1..160 bytes and its `pin` 1..128 bytes, and the room's input ID `mail:<message_id>` stays within 160 bytes when `message_id` is at most 155 bytes.
- `domain/principal` kinds are `:human`, `:service` and `:agent`. The sender kind set below restates them; the Piece calls no `domain/principal` function, so it does not depend on ELZ-267 (a coordinator check of the plan's dependency list).

## Interface

Module `Elzoo.DurableMailbox`. Every function takes the binding, the tenant and one request map, except `new/2` and `verify/1`.

- `Elzoo.DurableMailbox.Migration.install(prefix)`, called from a consumer migration's `up/0` by the table owner, installs the `state/tenant-isolation` readers in `prefix`, creates three tables in the existing schema `prefix` and protects each with `Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`, `space_column: nil`):
  - chains, `PRIMARY KEY (tenant, chain_id)`, with the declaration identity, the tip's sequence and the next message sequence;
  - links, `PRIMARY KEY (tenant, chain_id, seq)`, `UNIQUE (tenant, chain_id, predecessor_seq)`, `UNIQUE (tenant, run_id)` and `UNIQUE (tenant, unit_identity)`;
  - messages, `PRIMARY KEY (tenant, chain_id, message_id)`, `UNIQUE (tenant, chain_id, seq)`, an index for the oldest pending message of a chain.

  `prefix` follows the tenant-isolation identifier rule; anything else raises `ArgumentError` with one fixed message before any DDL. Nothing is reversible by the Piece.
- `new(opts, declaration)` takes `opts` exactly `repo:` and `prefix:` and a **declaration** `%{id, version, max_pending, messages}`: `id` 1..128 bytes of `[a-z0-9._-]`, `version` 1..2^31−1, `max_pending` 1..65,536 (no default), `messages` a map of 1..64 names (each 1..128 bytes of `[a-z0-9._-]`) to `%{schema_version: 1..2^31−1, schema: decoded_json_schema}`. Each schema is built at `new/2` with `Elzoo.PayloadSchema.build(%{"id" => name, "direction" => "input", "schema_id" => name, "schema_version" => schema_version}, schema)`. It returns `{:ok, mailbox}`, or `{:error, :invalid_declaration}` when any of this fails, including a schema that does not build. The declaration identity is `{id, version, sha256}`, the SHA-256 of the documented canonical encoding of the whole declaration (below).
- `verify(mailbox)` runs `Elzoo.TenantIsolation.verify/3` for the three tables and returns `:ok` or `{:error, {table, reason}}` for the first failing table (`table` one of `:chains`, `:links`, `:messages`). It has no `:in_transaction` check: `verify/3` also runs inside a caller's transaction. The host calls it, connected as the application role, before serving.
- A **link** is `%{seq, run_id, unit_identity, predecessor_seq, pin, planned_pin, carry, carry_kind, state, outcome, change_ref, stopped}`: `seq` from 1 in the chain; `predecessor_seq` `nil` for the first link, else `seq − 1`; `pin` the opaque recipe identity of the link's Run; `planned_pin` `nil` or the pin that its successor will have (`plan_rollover/3`); `carry` the JSON term that the link's Run starts with, at most 65,536 bytes of canonical JSON, kept for every link so that the start of every link stays readable; `carry_kind` `:opened` (the first link), `:finished` or `:restarted`; `state` `:live` (the tip) or `:closed`; `outcome` `nil` while live, then the host-vouched terminal outcome code of its Run (1..64 bytes of `[a-z0-9_]`); `change_ref` `nil` or the reference of the explicit pin change that made this link; `stopped` `false` until a `{:refused, :record_size}` settle (below). The link field list includes `stopped` and `planned_pin` (plan review M1).
- `open(mailbox, tenant, %{chain_id, run_id, unit_identity, pin, carry})` creates the chain with its declaration identity and its first link (`seq` 1, `carry_kind: :opened`, `state: :live`). `chain_id` is the correlation ID, 1..128 bytes. Idempotent by `(tenant, chain_id)`: the same request with the same declaration identity is `{:ok, :duplicate}`; another request, or the same request from a binding with another declaration, for the same `chain_id` is `:conflict`. Returns `{:ok, :applied}` or `{:ok, :duplicate}`.
- `put(mailbox, tenant, %{sender, address, message})`: `sender` is the host-vouched `%{kind: :human | :service | :agent, id}`; `address` is `{:chain, chain_id}` or `{:run, run_id}`; `message` is `%{message_id, name, schema_version, payload}` with `message_id` 1..155 bytes of valid UTF-8 without a C0 or C1 control character and `payload` a JSON term. A `{:run, run_id}` address of any link, live or closed, resolves to that link's chain, so mail to a superseded identity is mail to the chain and is delivered to the live tip. Returns `{:ok, :applied}` or `{:ok, :duplicate}` (below).
- `claim(mailbox, tenant, %{chain_id})` returns `{:ok, %{message: message, link_seq, run_id, unit_identity}}` for the claimed message with the live tip's facts, `{:ok, :empty}` when no message is pending, or `{:ok, :stopped}` when the tip is `stopped` (nothing is claimed). `message` is `%{message_id, sender, name, schema_version, payload, seq}`.
- `settle(mailbox, tenant, %{chain_id, message_id, link_seq, result})` with `result` one of `:applied` (the engine replied applied or duplicate), `:not_applied` (the host's own reading of the engine record shows the input absent while that Run is terminal or fenced) or `{:refused, reason}` (the input was not given, or is not shown to have been given, to a pattern) with `reason` one of the closed set `:record_size`, `:unacknowledged`, `:invalid_input` and `:input_id_conflict`.
- `plan_rollover(mailbox, tenant, %{chain_id, link_seq, change})` with `change` `nil` or `%{pin, ref}` (`ref` 1..256 bytes, the host's authorised, recorded action) records on the live tip `planned_pin`: the tip's `pin` when `change` is `nil`, else `change.pin`. It returns `{:ok, %{planned_pin: pin, previous: earlier_planned_pin_or_nil}}`, so a caller that plans another version knows the pin record it must remove.
- `rollover(mailbox, tenant, %{chain_id, link_seq, outcome, successor, change})` with `successor` `%{run_id, unit_identity, carry, carry_kind: :finished | :restarted}` and `change` as in `plan_rollover/3` returns `{:ok, %{seq: successor_seq}}`.
- `chain(mailbox, tenant, %{chain_id, after_seq, limit})` (`after_seq` `nil` or a sequence, `limit` 1..256) returns `{:ok, %{declaration: {id, version, sha256}, links: links, more: boolean, tip: tip}}`: the links after `after_seq`, oldest first, without their `carry`, and the tip link with its `carry`, its `stopped` flag and its `planned_pin`.
- `status(mailbox, tenant, %{chain_id, message_id})` returns `{:ok, %{state: :pending | :delivering | :consumed | :refused, link_seq, reason}}` (`link_seq` and `reason` `nil` where they do not apply), so a host that posted mail through an Effect and got an unknown outcome can read whether it was written.

Fields. `tenant`, `chain_id`, `run_id`, `pin`, a sender `id`: 1..128 bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes; `unit_identity`: 1..160 bytes of valid UTF-8 without NUL. A JSON term is `nil`, a boolean, an integer, a finite float, a valid UTF-8 binary, a proper list or a non-struct map with valid UTF-8 binary keys of such terms, at most depth 32. **Canonical JSON** is the compact encoding with the keys of every object sorted by their bytes; the README documents it, and it decides every equal-bytes comparison below. `carry` and `payload` are at most 65,536 bytes of canonical JSON.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or a payload: `:invalid_declaration` (only from `new/2`), `:invalid`, `:in_transaction`, `:isolation`, `:undeclared_name`, `:schema_version`, `:invalid_payload`, `:unknown_chain`, `:declaration_mismatch`, `:conflict`, `:mailbox_full`, `:identity_in_use`, `:unknown_link`, `:not_delivering`, `:not_tip`, `:delivery_unsettled`, `:already_rolled_over`, `:plan_mismatch`, `:unknown_message`, `:unavailable`.

## Rules

Every write checks the request's shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`), both before any query; then one transaction through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`, whose first query reads `current_setting('transaction_isolation')` and refuses anything but `read committed` as `:isolation`, before any write (as `domain/metering`). The writes are `open/3`, `put/3`, `claim/3`, `settle/3`, `plan_rollover/3` and `rollover/3`. `chain/3` and `status/3` check shape, then `:in_transaction`, then read under the tenant scope with no isolation check. Every statement runs with `log: false`. A refusal commits nothing. A database failure is `{:error, :unavailable}` and says nothing about whether a write committed; a retry with the same request is safe.

**The chain row lock.** Every write after `open/3` takes the chain row with `SELECT ... FOR UPDATE` before it reads or writes a link or a message of that chain, so the writes of one chain are serialized. The one read before it is the resolution of a `{:run, run_id}` address to its chain in `put/3`; links are never deleted and a `run_id` names one link of a tenant, so that read cannot go stale.

`put/3` checks, in this order, and stops at the first failure, before any write:

1. Shape and bounds (`:invalid`).
2. `name` is not a key of the binding's declaration: `:undeclared_name`.
3. `schema_version` is not the declared version of that name: `:schema_version`.
4. `PayloadSchema.check/3` of the payload against the name's built schema is not `:ok`: `:invalid_payload` (every refusal of that check, its violations not echoed).
5. `:in_transaction`, then the isolation check (steps 1–4 run before any query).
6. The address resolves to no chain of the tenant: `:unknown_chain`.
7. The binding's declaration identity is not the chain's: `:declaration_mismatch`.
8. A message of `(tenant, chain_id, message_id)` exists: with equal canonical bytes of the sender, name, schema version and payload it is `{:ok, :duplicate}` and changes nothing; otherwise `:conflict`. The address is not part of the comparison, so the same mail put once to the chain and once to a closed link's `run_id` is a duplicate.
9. The chain holds `max_pending` messages in state pending or delivering: `:mailbox_full`, with no eviction.
10. Insert the message as pending with the next chain sequence.

So an undeclared name or a payload that fails its schema leaves no row (settled decision 1). The order of steps 2–4 before the chain read is a coordinator choice: they need no query, and the declaration is the binding's, so step 7 refuses a binding whose declaration is not the chain's.

`claim/3`: under the chain row lock, when a message is delivering it returns that message again (it is delivering to the live tip, since `rollover/3` refuses a link with a delivering message); else when the tip is `stopped` it returns `{:ok, :stopped}`; else it marks the pending message with the lowest sequence delivering to the tip and returns it; else `{:ok, :empty}`. So a message is claimed by exactly one link, and a crash after `claim/3` and before the engine call gives the same message to the same link again.

`settle/3`: a settle that repeats the recorded final result of that message for that link (`:applied`, or `{:refused, reason}` with the same reason) is `{:ok, :duplicate}`; otherwise the message must be delivering to `link_seq`, else `:not_delivering` (so a repeated `:not_applied`, after which the message is pending again, is `:not_delivering`). `:applied` marks it consumed by that link; `:not_applied` returns it to pending with its sequence, so it is the oldest pending message again; `{:refused, reason}` marks it refused with the reason, a final state that `status/3` shows and that is never claimed again. `{:refused, :record_size}` also sets `stopped: true` on the link it was delivered to, in the same transaction.

`plan_rollover/3`: `:unknown_link` for a link the chain lacks, `:not_tip` unless the link is the live tip; otherwise it replaces `planned_pin`. A plan may be replaced only until `rollover/3`.

`rollover/3` is the atomic step, one transaction under the chain row lock:

1. `:unknown_link` for a link the chain lacks.
2. When the named link is closed: a successor recorded with equal canonical bytes of `outcome`, `successor` and `change` returns `{:ok, %{seq: that_successor}}` again; otherwise `:already_rolled_over`.
3. A message delivering to the link: `:delivery_unsettled`. A refused message does not block a rollover.
4. The successor's pin is the link's `pin`, or `change.pin` when `change` is set; no `planned_pin`, or one that differs from it, is `:plan_mismatch`.
5. A successor `run_id` or `unit_identity` that a link of the tenant already holds: `:identity_in_use`.
6. Mark the link closed with `outcome`, insert exactly one successor link (`seq + 1`, `predecessor_seq` the link's `seq`, the given carry and `carry_kind`, `change_ref` `change.ref` or `nil`, `stopped: false`, `planned_pin: nil`), and make it the tip. The primary key on `(tenant, chain_id, seq)` and the unique index on `(tenant, chain_id, predecessor_seq)` refuse a second successor row; the chain row lock serializes two rollovers, so the second one reads the closed link and gets step 2's answer. The Piece maps no unique violation to a result: it is `:unavailable`.

`open/3` refuses a `run_id` or `unit_identity` that a link of the tenant already holds with `:identity_in_use`, after its duplicate check. Two concurrent `open/3` calls of one `chain_id` create one chain; the other call returns `:duplicate` or `:conflict` by its bytes, not `:unavailable`.

The README states the minimum grants for the application role: `USAGE` on `prefix`; `SELECT, INSERT, UPDATE` on each of the three tables; no `DELETE`; and the PUBLIC defaults that the floor needs (`CONNECT` and `TEMP` on the database, `EXECUTE` on `elzoo_tenant_id()`). `piece.json` declares telemetry and control `not_applicable`, the config of the binding and the fixed bounds, and the dependencies `state/tenant-isolation` and `core/payload-schema`; the providers include `jason` for the canonical encoding.

## Kept open (owner's "no corner" rule)

Each option below can be added in place before the first release without breaking a caller: the address, sender-kind, refusal-reason, settle-result and error sets may gain members, and the request, link, message and result maps may gain optional keys that the canonical comparisons encode only when present. A caller matches on the members and keys it uses.

- *A host validator Need beside `core/payload-schema`:* an optional per-name key of the declaration.
- *A declaration change at a rollover:* an optional key of `rollover/3`; until then a chain keeps its declaration.
- *More address kinds* (a bot inbox, a member): new members of the address set.
- *Dead-lettering a refused message* through the ready `delivery/dead-letter-store`: a host composition over `status/3`, or an optional mode.
- *Message expiry and a purge of consumed mail:* an added operation (see the limits).
- *Priority lanes:* an optional message key with an ordered claim.
- *A push notifier* (`LISTEN/NOTIFY`) beside the claim: an optional mode.
- *Pruning a chain's links to an archive:* an added operation; `chain/3` already pages.

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 (`ELZOO_TEST_DATABASE_URL`) with a `DBConnection.ConnectionPool` Repo, not the Sandbox, in random schemas dropped afterwards.

1. The closed surface: each refusal of `put/3` steps 1–4 and 6–9, each checked before any write by a direct read of the three tables inside `Elzoo.TenantIsolation.transact/3` with the tenant's scope (the tables force row security, so a read outside a scope proves nothing): an undeclared name and a payload that fails its schema leave no row; `new/2` with a schema that does not build, 0 and 65 names, and a bad name is `:invalid_declaration`.
2. Bounds: `message_id` at 155 bytes is accepted and at 156 is `:invalid`; a payload and a carry of 65,536 canonical bytes are accepted and of 65,537 are refused; `max_pending` 0 and 65,537 are refused.
3. Duplicate and conflict for `open/3` and `put/3`, including the same mail put to the chain and to a closed link's `run_id`; two concurrent `open/3` calls of one `chain_id` with equal bytes give one chain and one `:duplicate`.
4. FIFO: three messages are claimed in their order; a `:not_applied` settle makes that message the next claim again.
5. `mailbox_full` at `max_pending` 1 and 2 (the edge, and one under it); a duplicate of a stored message at the bound is `:duplicate`.
6. Mail addressed to a closed link's `run_id` is claimed for the tip, with the tip's `run_id` and `unit_identity`.
7. Claim against rollover: another connection holds the chain row lock (`SELECT ... FOR UPDATE` in an open transaction) until a `claim/3` and a `rollover/3` of the tip both wait on it (seen in `pg_locks` as ungranted locks), each seen waiting before the next starts. With the claim queued first, the rollover is `:delivery_unsettled`; in a fresh schema with the rollover queued first, the claim names the successor.
8. Two concurrent rollovers of one link behind the same barrier commit one successor; the other is `{:ok, %{seq: same}}` with equal bytes and `:already_rolled_over` with other bytes; a direct insert of a second link with the same predecessor fails on the unique index.
9. A crash after `claim/3` (the connection is dropped before any settle) gives the same message to the same link at the next claim.
10. `settle/3` with each result and each refusal reason; a repeated `:applied` or refused settle is `:duplicate`, and a repeated `:not_applied` is `:not_delivering`; a settle for another link is `:not_delivering`; a refused message no longer blocks a rollover and `status/3` shows it refused with its reason; `{:refused, :record_size}` sets `stopped`, `chain/3` shows it, and `claim/3` then returns `{:ok, :stopped}`.
11. The pin: carried over with `change: nil`, changed only with `change`, and the successor's `change_ref` recorded; `plan_rollover/3` replaced before the rollover returns the earlier plan as `previous`; `rollover/3` with no plan, and with a pin other than the planned one, is `:plan_mismatch`; `plan_rollover/3` of a closed link is `:not_tip`.
12. `:identity_in_use` for a successor that reuses a `run_id` or a `unit_identity` of any link of the tenant, and for an `open/3` that does; the same IDs in another tenant are accepted.
13. `chain/3` paging at `limit` 1 and 256 with `more`, the tip with its carry; `status/3` of each state and `:unknown_message`.
14. Row security as `elzoo_app` (ELZ-285: `SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection, only the README grants on the random schema; the test fails, not skips, when the variable is unset): `verify/1` passes; under T1 a T2 chain is `:unknown_chain` for `put/3`, `claim/3` and `chain/3`; a direct SQL insert of a T2 row into each table fails with SQLSTATE 42501; `DELETE` of a message fails with 42501; every function succeeds with only the README grants.
15. A caller's open transaction gives `:in_transaction` for every function except `new/2` and `verify/1` before any query, and `verify/1` inside a caller's transaction gives the same result as outside it; a Repo whose connections default to `repeatable read` gets `:isolation` from every write with nothing committed.
16. Negative controls, one at a time, each restored before the final gates: skip the payload check (case 1's invalid-payload case fails); drop the chain row lock of `rollover/3` (case 8 fails: the two rollovers no longer wait behind the barrier, and the second gets `:unavailable` from the key instead of `{:ok, %{seq: same}}` or `:already_rolled_over`; the key and the index still keep one successor); remove the `:delivery_unsettled` check (case 7's claim-first order leaves a message delivering to a closed link).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide ("Reviewer by risk": it finds the code and a test for each rule above), the exact-head hosted check and the merge queue are required. Record in the pull request body the change in the time of the aggregate consumer of `test/export_test.exs` (#814, #819).

## Limits to state

The `state/tenant-isolation` limits apply (the table owner can turn forcing off or drop the policies; a superuser or `BYPASSRLS` role ignores them). READ COMMITTED is a consumer Need that the Piece checks but cannot set. The sender, the terminal outcome, the change reference and the `:not_applied` and refused readings are host-vouched. A message is delivered to exactly one link, not exactly once end to end; the engine's input IDs decide what a Run saw. Mail payloads hold people's text and have no delete, expiry or erasure in Wave 8 (dead tuples, WAL and backups keep content until PostgreSQL reclaims them). Links are never pruned, so a chain grows by one row per rollover. `log: false` silences only the Logger: the Repo's query telemetry still receives the parameters. No Run start, engine call, timer, notifier or priority.
