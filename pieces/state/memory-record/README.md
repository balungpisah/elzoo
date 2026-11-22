# state/memory-record

Facts, preferences and summaries about a tenant, a space, an end user or a bot, kept as
immutable scoped records with provenance, written only through a host policy, recalled within
bounds in the candidate shape of `workflow/context-selection`, and forgotten or erased on
request. One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on
PostgreSQL 16; its two tables are protected by the `state/tenant-isolation` floor.

A scope is a tagged value of the record, and the write policy is the pure `check_write/2` of
this Piece, which `write/4` runs before every write (they absorb the plan's handles
`domain/memory-scope` and `workflow/memory-write-policy`, which have no Piece of their own).
The Piece has no embedding, search, extraction, model call, clock or process.

A memory is content, never an instruction or a truth, whatever its kind: it is stored and
returned as a `workflow/untrusted-content` marked value with its trust class, sources and bound.

## Copy and providers

Select `state/memory-record` with `mix elzoo.take`; the dependency-closed copy is owned by the
consuming application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation` (the floor, its migration helper and `transact/3`),
`workflow/untrusted-content` (`decode/1` and `encode/1` of the marked content) and
`workflow/context-selection`, which is declared only so that the copied consumer can run the
tests: they pass the recall candidates through `Elzoo.ContextSelection.select/2`, and the
library code does not call it. Cure source: [cure/elzoo/memory_record.cure](cure/elzoo/memory_record.cure)
owns the policy decision. Providers: `cure`, `ecto_sql` 3.14.0 and `postgrex` 0.22.4, `elixir`,
`otp` (`:crypto` SHA-256); the tests also use `telemetry` and `jason`. Exact versions and claim-level
grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.MemoryRecord.Migration.install(prefix)` from the `up/0` of a consumer Ecto
migration, run by the table owner, in an existing schema `prefix`. It installs the
tenant-isolation readers in `prefix` (`CREATE OR REPLACE`), creates two tables and protects
each with `Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`,
`space_column: nil`):

- `elzoo_memory_records`: `PRIMARY KEY (tenant, memory_id)`; the scope as `scope_kind` and
  `scope_id` (`''` for `{:tenant}`), `kind`, the six fields of the marked content (the content
  as `bytea`), the provenance as two parallel arrays, `written_by`, `writer_kind`,
  `written_at_ms`, `expires_at_ms`, `supersedes`, the approval reference and the proposal
  `digest`. Indexes on `(tenant, scope_kind, scope_id, written_at_ms DESC, memory_id)` for
  recall, `(tenant, scope_kind, scope_id, memory_id)` for erasure and `(tenant, supersedes)`.
- `elzoo_memory_tombstones`: `PRIMARY KEY (tenant, memory_id)`; `scope_kind`, `scope_id`,
  `supersedes`, `forgotten_at_ms`, `actor_ref` and `reason`. No content and no provenance.

Every text column that the Piece compares or orders is `COLLATE "C"`, so IDs compare and sort
by bytes. `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError`
with the fixed message `"invalid memory record repo or prefix"` before any DDL is queued.
Nothing is reversible by the Piece; a `down/0` is the consumer's.

### Grants

The application role needs exactly these, and nothing else:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, DELETE ON prefix.elzoo_memory_records TO app_role;
GRANT SELECT, INSERT ON prefix.elzoo_memory_tombstones TO app_role;
```

plus the PUBLIC defaults that the floor needs: `CONNECT` and `TEMP` on the database
(`Elzoo.TenantIsolation.verify/3` needs `TEMP` for its rebuild) and `EXECUTE` on the
`state/tenant-isolation` reader `prefix.elzoo_tenant_id()`, the one reader that the floor calls
when it has no space column. With no `UPDATE` grant a record is immutable, and with no `DELETE`
on tombstones a forget cannot be undone (SQLSTATE 42501). Connect the application as a
non-owner role that does not bypass row security, and call `Elzoo.TenantIsolation.verify/3`
for both tables at startup.

## Interface

```elixir
memory = Elzoo.MemoryRecord.new(repo: MyApp.Repo, prefix: "memory")

{:ok, content} = Elzoo.UntrustedContent.decode(%{
  "schema_id" => "elzoo.untrusted-content.marked", "schema_version" => 1,
  "sources" => ["run:run-7"], "trust" => "derived", "max_bytes" => 4096,
  "content" => "Prefers replies in Indonesian."
})

proposal = %{
  memory_id: "mem-1", scope: {:subject, "user-9"}, kind: :preference, content: content,
  provenance: [{:run, "run-7"}, {:message, "msg-3"}],
  written_by: "agent-run-7", writer_kind: :agent,
  written_at_ms: 1_795_000_000_000, expires_at_ms: nil, supersedes: nil
}

policy = %{{:subject, :preference, :agent} => :ask, {:tenant, :fact, :human} => :allow}

Elzoo.MemoryRecord.check_write(policy, proposal)          #=> {:ask, :policy}
Elzoo.MemoryRecord.write(memory, "tenant-1", proposal, %{policy: policy})
#=> {:error, :approval_required}

{:ok, digest} = Elzoo.MemoryRecord.digest("tenant-1", proposal)
# The host asks a person through workflow/approval, naming this digest, then:
Elzoo.MemoryRecord.write(memory, "tenant-1", proposal,
  %{policy: policy, approval: %{ref: "approval-4", digest: digest}})
#=> {:ok, :applied}
```

- **Scope**: `{:tenant}`, `{:space, id}`, `{:subject, id}` or `{:bot, id}`; its scope kind is
  the first element. **Kind**: `:fact`, `:preference` or `:summary`. **Writer kind**: a
  `domain/principal` kind, `:human`, `:service` or `:agent`; a model's proposal is written
  under the Run's `:agent` principal.
- **Proposal**: exactly `%{memory_id, scope, kind, content, provenance, written_by,
  writer_kind, written_at_ms, expires_at_ms, supersedes}`. `content` is a marked value from
  `Elzoo.UntrustedContent.decode/1` whose content is 1..4,096 bytes, stored whole.
  `provenance` is 1..16 distinct references `{kind, id}` in order, `kind` one of `:run`,
  `:message`, `:artifact` and `:person`. `expires_at_ms` is `nil` or a time; `supersedes` is
  `nil` or another memory ID.
- `new(opts)` takes exactly `repo:` and `prefix:` and returns a memory value, or raises the
  fixed `ArgumentError`.
- `digest(tenant, proposal)`: `{:ok, sha256}` of the encoding below, or `{:error, :invalid}`.
- `check_write(policy, proposal)` is pure. `policy` is a map, possibly empty, of at most 36
  triples `{scope_kind, kind, writer_kind}` to `:allow`, `:ask` or `:deny`. It returns
  `:allow`, `{:ask, :policy}`, `{:deny, :policy}` for a listed `:deny`, `{:deny, :unlisted}`
  for a triple that the policy does not list, or `{:error, :invalid}`. There is no default
  policy: an empty policy denies every write.
- `write(memory, tenant, proposal, %{policy: policy})` or with `approval: %{ref, digest}` (a
  `ref` of 1..256 bytes, a 32-byte `digest`): `{:ok, :applied}`, or `{:ok, :duplicate}` for
  the same `(tenant, memory_id)` with an equal digest. It writes only on `:allow`, or on
  `{:ask, :policy}` with an approval whose `digest` equals `digest(tenant, proposal)`; an
  approval given on an `:allow` is checked the same way. The Piece checks only the digest and
  keeps `ref` with the record: the host obtains the approval through `workflow/approval`.
- `recall(memory, tenant, request)`: `request` is exactly `%{principal, checked_at, scopes,
  max_records, max_bytes, now_ms}` and optionally `kinds`: 1..16 distinct scopes, 1..3 distinct
  kinds (absent means all), `max_records` 1..256 and `max_bytes` 1..1,048,576.
  `{:ok, %{entries: entries, more: boolean}}`, described below.
- `forget(memory, tenant, %{memory_id, actor_ref, reason, forgotten_at_ms})`: deletes the
  record's row and keeps a tombstone `{memory_id, scope, supersedes, forgotten_at_ms,
  actor_ref, reason}` in the same transaction. `{:ok, :applied}`, `{:ok, :duplicate}` when
  already forgotten (the first tombstone stays) or `{:error, :unknown_memory}`. A forgotten ID
  is never written again.
- `erase_subject(memory, tenant, %{subject, actor_ref, forgotten_at_ms, cursor, max_batch})`:
  `cursor` is `nil` or a memory ID, `max_batch` 1..256. One call takes, in `memory_id` byte
  order after `cursor`, the first `max_batch` IDs of scope `{:subject, subject}` among records
  and tombstones together, forgets the live ones with reason `"subject_erasure"` and returns
  `{:ok, %{forgotten: ids, cursor: next}}`, `ids` all of those IDs and `next` the last of them,
  or `nil` when no ID of the scope follows. A repeat from `cursor: nil`, also after a stop
  mid-cleanup, returns the subject's forgotten IDs again from the tombstones.

### Recall entries

Current records of the named scopes and kinds: not superseded (by a record or a tombstone that
names them), not forgotten and not expired (`expires_at_ms <= now_ms` is expired). Newest
first (`written_at_ms` descending, then `memory_id` ascending by bytes); the list stops at
`max_records` entries or before the first record whose content would bring the sum of content
bytes over `max_bytes`, and `more` is `true` exactly when a current matching record was left
out. Each entry is `%{candidate, node, scope, kind, marked, updated_at}`:

- `candidate`: `item_id` (the memory ID), `version: 1`, `source` (`"memory:" <> memory_id`),
  `content`, `content_hash` (its raw SHA-256), `derived_from: []` (recall has applied
  supersession) and `access: %{principal, checked_at, result: :allowed}`, restating the request.
- `node`: `item_id`, `version`, `tenant`, `source`, `content_hash`, `derived_from: []` and
  `check: nil`.
- `scope` and `kind` of the record, `marked` the neutral map of its content, `updated_at` its
  `written_at_ms`.

### Fields

| Field | Rule |
| --- | --- |
| `tenant`, `memory_id`, a scope ID, a provenance ID, `written_by`, `actor_ref`, `principal`, `subject`, `supersedes`, `cursor` | 1..128 bytes of valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F), compared by exact bytes |
| `reason` | 1..64 bytes of `[a-z0-9_.:-]`: a code, not prose, so no personal text is kept after a forget |
| approval `ref` | 1..256 bytes under the ID rule |
| `written_at_ms`, `expires_at_ms`, `forgotten_at_ms`, `checked_at`, `now_ms` | integers 0..2^53−1, host-supplied Unix milliseconds that the Piece only compares |

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or content: `:invalid`,
`:in_transaction`, `:isolation`, `:denied`, `:approval_required`, `:approval_mismatch`,
`:forgotten`, `:conflict`, `:unknown_supersedes`, `:already_superseded`, `:unknown_memory`,
`:unavailable`.

The scope, kind, provenance-kind, writer-kind, decision and error sets may gain members, and
the proposal, request, result and entry maps may gain optional keys, in a later in-place
version (for example a `{:conversation, id}` scope, per-record access labels, a TTL sweep,
content sealed in the `state/retention-erasure` vault, or recall by meaning); match on the
members and keys you use. The policy bound of 36 triples is the size of the closed sets of this
version and grows with them.

## Rules

`write/4` checks, in this order, and stops at the first failure:

1. Shape and bounds of the proposal, the policy and the approval (`:invalid`).
2. `check_write/2`: a deny is `:denied`; an ask without an approval is `:approval_required`;
   an approval whose digest differs from `digest(tenant, proposal)` is `:approval_mismatch`.
3. `repo.in_transaction?()` (`:in_transaction`). Steps 1–3 run before any query.
4. One transaction through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`;
   its first query reads `current_setting('transaction_isolation')` and refuses anything but
   `read committed` as `:isolation`.
5. The per-ID locks on `memory_id` and, when `supersedes` is set, on the predecessor, in the
   lock order below. Then a tombstone of `memory_id` is `:forgotten`.
6. An existing record of `memory_id` with an equal digest is `{:ok, :duplicate}`; with another
   digest it is `:conflict`.
7. When `supersedes` is set: no such record (absent or forgotten), or one of another scope, is
   `:unknown_supersedes`; a predecessor that already has a successor (a record or a tombstone
   whose `supersedes` names it) is `:already_superseded`. So a record has at most one
   successor, and forgetting a successor does not make its predecessor current again.
8. Insert the record.

`forget/3` and `erase_subject/3` check shape, then `:in_transaction`, then the isolation check.
`forget/3` then takes the per-ID lock and deletes the record row with `DELETE ... RETURNING`,
inserting the tombstone in the same statement. `erase_subject/3` reads the batch's IDs, takes
their per-ID locks in the lock order, and deletes the live ones the same way. `recall/3`
checks shape, then `:in_transaction`, then runs one statement under the tenant scope (no
isolation check). A refusal commits nothing. A database failure is `{:error, :unavailable}`
and says nothing about whether a write committed; a retry with the same request is safe.

### The per-ID lock

Writers are serialized by `pg_catalog.pg_advisory_xact_lock(key)`, where `key` is the first 8
bytes, as a signed 64-bit big-endian integer, of SHA-256 over `"elzoo.memory-record.lock" <>
<<0>>` followed by `prefix`, `tenant` and `memory_id`, each as `<<byte_size(item)::32,
item::binary>>`. It is not a row lock: `SELECT ... FOR UPDATE` and `FOR SHARE` need the
`UPDATE` privilege, which the application role does not have. A function that takes more than
one per-ID lock takes each distinct key once, in ascending order, so two callers never wait on
each other in a cycle; two IDs that share a key only serialize more. So a write, a forget and
an erase of one ID are serialized: a forget that commits while a write waits is seen by the
write's step 5, and a record and a tombstone of one ID never both exist.

### Proposal digest

The digest is SHA-256 over `"elzoo.memory-record.proposal" <> <<0>>` followed by one pair per
field, sorted by name by bytes, each pair `frame([name, value])`, where `frame(items)` is each
item as `<<byte_size(item)::32, item::binary>>` (a 32-bit unsigned big-endian length). The
fields and their values:

| Name | Value |
| --- | --- |
| `content` | the content's neutral map: one `frame([key, value])` per key, sorted by key; text as its bytes, an integer as ASCII decimal, `sources` as `frame(sources)` |
| `expires_at_ms` | ASCII decimal, or empty for `nil` |
| `kind`, `writer_kind` | the atom name |
| `memory_id`, `tenant`, `written_by` | the bytes |
| `provenance` | `frame` of each reference's `frame([kind_name, id])`, in order |
| `scope` | `frame(["tenant"])`, or `frame([scope_kind_name, id])` |
| `supersedes` | the bytes, or empty for `nil` |

`written_at_ms` is not encoded, so a retry at another time is a duplicate. A field that a later
in-place version adds as optional is encoded only when present, so existing digests, the
duplicates they decide and the approvals that name them stay equal.

## Composition

1. The host tokenizes personal values with `integration/pii-redaction` and the
   `state/retention-erasure` vault before a write; this Piece calls neither.
2. It writes through its own policy; an `:ask` goes through `workflow/approval`, naming
   `digest/2`.
3. It recalls the scopes that the principal may read, completes each candidate with
   `estimate` and `priority` (and `updated_at` for `recency: :newest`), and sets each node's
   `check` from its own current reading of whether the principal may read that memory's scope
   (a subject's own record, a space membership), because context-selection never takes current
   access from request data:

   ```elixir
   {:ok, %{entries: entries}} = Elzoo.MemoryRecord.recall(memory, tenant, request)
   candidates = for e <- entries,
     do: Map.merge(e.candidate, %{estimate: byte_size(e.candidate.content), priority: 0})
   nodes = for e <- entries, do: %{e.node | check: host_check(e.node, e.scope)}
   Elzoo.ContextSelection.select(%{candidates: candidates}, %{context | provenance: nodes})
   ```

   A selected memory goes to the `memory` part of `workflow/prompt-assembly` as
   `%{id: memory_id, content: entry.marked}`.
4. On a forget or an erasure it deletes each returned memory's `integration/search-data`
   source, if it indexed one (recall by meaning is that composition, not this Piece).

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them.
- READ COMMITTED is a consumer Need that the Piece checks but cannot set.
- The writer kind, `written_by`, the approval reference and the request's principal are
  host-vouched; the Piece checks only that an approval names the exact digest. Recall returns
  the scopes the host names and does not decide who may read them.
- A memory is content, never an instruction or a truth, whatever its kind.
- A forget deletes the row, not dead tuples, WAL or backups, which keep content until
  PostgreSQL reclaims them; tombstones keep opaque IDs, including the subject ID of an erased
  scope. Crypto-shredding covers only the values that the host tokenized.
- A record written for a subject while `erase_subject/3` walks past its ID is left for a repeat
  from `cursor: nil`.
- No embedding, search, extraction, model call, TTL sweep or per-record access label. Expired
  records stay stored until forgotten.
- An `erase_subject/3` batch reads at most `max_batch + 1` rows of each table when PostgreSQL
  plans its statement for the given cursor, as it does by default for the Piece's unnamed
  statements. Under a generic plan (`plan_cache_mode = force_generic_plan`) the forced row
  security leaves the cursor comparison a filter, so one batch reads the subject's IDs up to
  the cursor.
- The Repo must be a started Ecto Repo: an unstarted Repo or another module raises from
  `in_transaction?/0` instead of returning an error atom.
- The Piece emits no telemetry and no log, and its queries pass `log: false`; the consumer
  Repo's query telemetry still receives their parameters (tenant, IDs and content).

## Evidence

[test/elzoo/memory_record_test.exs](test/elzoo/memory_record_test.exs) runs on the worker's own
disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) with
`DBConnection.ConnectionPool` Repos, not the Sandbox, in random schemas dropped afterwards.
Every Piece call runs as the ELZ-285 application role (`SET ROLE` to `ELZOO_TEST_APP_ROLE` on
every connection) with only the grants above; the tests fail, not skip, without that variable.
The Cure laws are listed in [piece.json](piece.json). Finite scenarios, not proofs.
