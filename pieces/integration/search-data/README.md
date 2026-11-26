# integration/search-data

A PostgreSQL/pgvector store for bounded, permission-scoped chunk retrieval.
Consumers own their Ecto Repo, Postgrex types module, schema deployment, access
snapshot and final context-selection call. The store never calls an embedding
provider or decides permission. Exact cosine search and, for an index declared with a text
search configuration, PostgreSQL full-text search over the same rows; no ANN index. A source
can be deleted, a write can be guarded to keep the newest version, and the tables can be put
under the `state/tenant-isolation` row-security floor. A binding without the new keys behaves
as before.

## Installation and Needs

Copy this Piece and its declared dependency closure, which includes `state/tenant-isolation`
also for a binding without the floor. Add the pinned providers
listed in piece.json, including pgvector 0.4.2 (MIT), and configure the consumer Repo:

```elixir
Postgrex.Types.define(MyApp.Types,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(), [])
# Consumer Repo configuration: types: MyApp.Types
```

PostgreSQL 19 with pgvector 0.8.x is an operator-provided Need. Its extension-owned
`vector` type and cosine operator must be visible through every Repo connection's
search_path. A catalog entry alone does not establish availability. The helper
checks the visible type's extension ownership and the extension-owned visible
cosine operator, then uses that same unqualified vector type/operator in SQL.
A same-named unrelated type is not accepted. The helper never creates or drops
the extension, starts a Repo, supplies credentials, or changes connection settings.
The consumer owns trusted schemas/search_path and prevents hostile DDL changes.

```elixir
descriptor = %{provider: "openai", model: "text-embedding-3-small",
  dimensions: 3, dtype: :float32, normalization: :unit_l2_verified}
declaration = %{index_identity: "manuals", descriptor: descriptor, metric: :cosine}
{:ok, binding} = Elzoo.SearchData.new(MyApp.Repo, declaration,
  prefix: "public", statement_timeout_ms: 5000)
{:ok, ^binding} = Elzoo.SearchData.Migration.install(binding)
```

`new/3` is pure configuration validation. `Migration.install/1` is the explicit
schema-deployment operation run outside a caller transaction; it installs a
prefix-local declaration registry and one fixed-dimension vector table. It
requires the prefix to exist. A repeated identical install is idempotent; a
second declaration with the same index identity and a different descriptor or
metric is refused. No business COMMIT receipt is claimed for schema installation.
Physical table names are generated from the identity; registry uniqueness
prevents two declared identities from sharing a physical table. `install/1` also creates
the index's delete-mark table (`elzoo_deletes_<40 hex>`, `PRIMARY KEY (tenant, source_ref)`)
with `CREATE TABLE IF NOT EXISTS`: re-run `install/1` once for an index installed before
delete marks existed (a Need of `delete_source/4` and the version guard; until then both
refuse `invalid_request` with nothing changed).

Every store operation checks the persisted declaration again. A binding cannot
silently switch the model/dimension/normalization of an existing index. The five
fields must exactly match Elzoo.AiEmbedding.Descriptor.compatible?/2. Dimensions
are 1..16000 (pgvector's storage bound, not an ANN-index bound); this slice accepts
only float32 and unit_l2_verified cosine vectors. Actual vector length, finite
float32 range, unit norm tolerance 1.0e-3 and provider/model provenance are checked.
Pgvector encodes vectors as float32, so Elixir double-precision input values are
rounded for storage; bitwise preservation of input doubles is not promised.

## Lexical search (optional per index)

```elixir
declaration = %{index_identity: "manuals-text", descriptor: descriptor, metric: :cosine,
  text_search: %{config: "english"}}
```

`config` names a text search configuration in schema `pg_catalog` (such as `simple` or
`english`) matching `^[a-z_][a-z0-9_]{0,62}$`. Every statement uses it as
`pg_catalog.<name>`, sent as a `text` parameter and cast by PostgreSQL, so neither the writer's
nor the reader's search_path can pick another configuration. It is part of the persisted
declaration: a second install with another configuration, or with the key added or removed, is
`incompatible_embedding`, and an index installed without it needs a new index identity to gain
it. A declaration without the key keeps exactly its earlier stored bytes.

An identity already installed with other declaration bytes is `incompatible_embedding` first,
also when the new configuration name is unknown. With the key, `install/1` then refuses a
non-UTF-8 database (`database_encoding`, an operator
Need; this refusal is not tested because the test role cannot create a database) and a
configuration that is not in `pg_catalog` (`unknown_text_search_config`, also when one of that
name exists in another schema). It then adds a plain `text_vector tsvector NOT NULL` column
with a GIN index (`content` is `bytea` and `convert_from` is not immutable, so no generated
column). Each put fills it in the same `INSERT` with
`to_tsvector(config, convert_from(content, 'UTF8'))`. Under the key a chunk containing a NUL
byte refuses the whole put `invalid_chunk` before any query, and a chunk whose `tsvector` passes
PostgreSQL's 1 MB limit refuses it `text_search_too_large` with nothing stored. PostgreSQL leaves
out words over 2,047 bytes, so a chunk of one long token is not found.

```elixir
request = %{tenant: tenant, text: "quick \"brown fox\" -dog", k: 20,
  allowed_sources: permitted_source_refs, principal: principal, checked_at: snapshot_time}
{:ok, candidates} = Elzoo.SearchData.query_text(binding, request)
```

`text` is 1..4096 bytes of valid UTF-8 without NUL, parsed with `websearch_to_tsquery`, so no
query syntax error is possible. A text that PostgreSQL finds too complex to parse (for example
a run of 33 or more `-`: SQLSTATE 54000 "tsquery is too complex" on PostgreSQL 16.16, the
internal error XX000 "tsquery stack too small" on 16.15 and earlier) is
`{:error, :invalid_request}`, not `unavailable`, so a host does not retry it. The other keys and bounds are those of `query/2`. Tenant and
permitted sources apply in the `WHERE` before ranking; rows match by `@@` and order by
`ts_rank_cd` descending, then source reference in C collation, version and chunk index. The
content bound and its overflow refusal are those of `query/2`. A candidate has the keys of a
`query/2` candidate with `rank` (a float) in place of `distance` and the same `item_id` for the
same row, so a host can fuse both lists. A stop-word-only query and an empty permitted list
return `{:ok, []}`; a binding without `text_search` is `{:error, :text_search_disabled}` before
any query. No relevance, language detection or typo tolerance is claimed.

## Writing a source

```elixir
# chunks: Elzoo.TextChunking.chunk/4 result.chunks
# The caller groups chunk texts into separate embedding calls while each exact
# canonical command payload fits the embedding interface's 65536-byte bound.
# For each call, join its embeddings item by its position in that batch:
joined_chunk = Map.put(chunk, :embedding,
  Map.merge(item, %{descriptor: completed.descriptor, provenance: completed.provenance}))
Elzoo.SearchData.put_source(binding, tenant,
  {source_ref, version, source_digest}, joined_chunks)
```

Each chunk has exactly `index,start_byte,end_byte,content,content_digest,embedding`.
The embedding has exactly `index,vector,descriptor,provenance`. The embedding
index remains batch-local and can be 0 on a source chunk whose global index is 32;
never rewrite the provider index to the source index. The caller owns association
of each batch input/item with its source chunk. The store checks shape and values,
not that a provider actually generated a claimed vector.

Chunk indices are dense in source order from 0. Content is nonempty UTF-8; offsets
are nonnegative integers and their difference equals content bytes. Chunk SHA-256
is rechecked. The source digest is a raw 32-byte SHA-256 supplied by the caller;
without the frozen full source this store cannot authenticate that digest or
verify that every offset refers to the claimed original bytes. Preserve the
chunker's frozen-source result and completed embedding provenance at the caller.

A write atomically deletes all old rows of tenant/source and inserts the complete
new version. A transaction-scoped advisory lock serializes replacements, including
an initially absent source. Other readers see old or new rows, never a partly
replaced source within a query snapshot. Primary-key/non-null constraints retain
row identity and provenance. Concurrent successful replacements are serialized.
An unguarded write replaces any version, also a higher one, and ignores delete marks.

`put_source(binding, tenant, source, chunks, if_newer: true)` adds a version guard: under the
same lock and in the same transaction, before it deletes, it refuses `stale_version` when the
stored version is higher than the new one, or the source's delete mark is equal or higher. An
equal stored version is replaced, so a repeated write of one version succeeds. `opts` is a
keyword list whose only key is `if_newer` (a boolean); anything else is `invalid_request`.
`put_source/4` is `put_source/5` with `[]`.

## Deleting a source

```elixir
{:committed, removed_rows} = Elzoo.SearchData.delete_source(binding, tenant, source_ref, version)
```

Under the same advisory lock as a put, in one transaction, it removes every row of the tenant
and source when the stored version is equal to or lower than `version`, raises the source's
delete mark to `max(mark, version)` and returns the row count (0 for an absent source, so a
repeat is idempotent). A higher stored version is `stale_version` and stays. A delete of
version v covers every stored version up to v, so a replay of it after an unguarded
`put_source` of version v removes that restored source; a host that restores a deleted source
writes it at a version higher than the delete. Other results are
those of `put_source/4`. A delete removes rows, not dead tuples, WAL or backups, which keep
content until PostgreSQL reclaims them; there is no expiry or retention schedule.

READ COMMITTED is a consumer Need of `delete_source/4` and of a guarded put: under REPEATABLE
READ the snapshot is taken before the lock wait, so a mark or rows committed during the wait
would stay invisible. Both read `transaction_isolation` before taking the lock and refuse
anything else `isolation` with nothing changed. The guard holds only between guarded writes
and deletes; the Piece checks the level but cannot set it.

Returns `{:committed, count}`, `{:refused, reason}`, or
`{:indeterminate, :unavailable}`. Refusal reasons are invalid_request,
invalid_chunk, source_too_large, incompatible_embedding, extension_missing,
text_search_too_large, stale_version and isolation. Refusals are fixed atoms that never echo a
tenant, source, text or content.
No partial-source success is returned. Conservative indeterminate covers lost
COMMIT observation and other unexpected DB errors; retry/reconciliation policy
belongs to the caller. After an indeterminate put, repeat it with `if_newer: true` or read back
first, never as an unguarded put, which can replace a newer version; an indeterminate
`delete_source/4` may be repeated as is (it is version-checked and idempotent). The store does
not claim external exactly-once Effects.

## Reading and completing candidates

```elixir
request = %{tenant: tenant, query_embedding: joined_query_item, k: 20,
  allowed_sources: permitted_source_refs, principal: principal, checked_at: snapshot_time,
  max_content_bytes: 8_388_608, statement_timeout_ms: 5000}
{:ok, candidates} = Elzoo.SearchData.query(binding, request)
```

The tenant and permitted-source list apply in the SQL WHERE before ordering and
limit. Results order by cosine distance, source reference in C collation, version,
then chunk index. An empty permitted-source list returns no rows. Exact top-k is
relative to stored rows and pgvector's distance operator; relevance is not truth
or ranking quality. One SQL statement materializes the ordered top-k identities and content sizes,
then admits content retrieval only when their entire total fits. An oversized
list returns an overflow marker without chunk content through the Repo; the
public reply is `{:error,:invalid_request}` with no rows. Ranking is not changed
and no smaller partial list is returned. This bounds selected content delivered
to the client, not all PostgreSQL work, protocol overhead or total BEAM heap. Other read errors are unavailable, incompatible_embedding
and extension_missing. Raw SQL/exception/parameter values are never returned.

Each candidate carries `item_id,version,source,content,content_hash,derived_from: [],
access: %{principal,checked_at,result: :allowed},distance,source_digest,start_byte,end_byte`.
Item identity is a deterministic SHA-256 over an unambiguous source/version/index
encoding. Retrieval access only restates the caller's snapshot. It grants no
current authorization. Complete the exact context-selection candidate shape:

```elixir
candidate = retrieved
  |> Map.take([:item_id,:version,:source,:content,:content_hash,:derived_from,:access])
  |> Map.merge(%{estimate: byte_size(retrieved.content), priority: 0})
# Supply its matching provenance node and a current host-owned permission check
# in context, then call Elzoo.ContextSelection.select/2. Revocation vetoes it.
```

## Tenant floor (optional)

```elixir
{:ok, binding} = Elzoo.SearchData.new(MyApp.Repo, declaration,
  prefix: "search", tenant_isolation: %{prefix: "tenancy"})
{:ok, ^binding} = Elzoo.SearchData.Migration.install(binding)   # run time, as the table owner

defmodule MyApp.Repo.Migrations.ProtectSearch do
  use Ecto.Migration
  def up, do: Elzoo.SearchData.Migration.protect(MyApp.Search.binding())
end

:ok = Elzoo.SearchData.verify(binding)   # as the application role, before serving
```

`tenant_isolation.prefix` is the schema of the `state/tenant-isolation` readers; it and the
binding's own `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`. A binding without the option has
exactly the keys `repo, prefix, declaration, statement_timeout_ms`.

`Migration.protect/1` runs from a consumer Ecto migration's `up/0`, after the run-time
`install/1` (which refuses a caller's transaction, and a migration runs in one): it installs the
readers and protects the vector table and the delete-mark table (`tenant_column: "tenant"`,
`space_column: nil`). A binding without `tenant_isolation` raises `ArgumentError` with the fixed
message `"search data binding has no tenant_isolation option"` before any DDL. When either table
already holds a tenant ID outside tenant-isolation's scope rule (over 128 bytes, or with a C0 or
C1 control character), which no call could reach under the floor, `protect/1` raises a
`RuntimeError` with the fixed message
`"search data index holds tenant IDs outside the tenant isolation scope"`, naming no tenant,
before any DDL: move or remove those rows, then run the migration again. The check first takes
`LOCK TABLE <vector table>, <delete-mark table> IN ACCESS EXCLUSIVE MODE`, in the order that the
floor DDL and the writers use, and holds it until the migration commits. No row can commit
between the scan and the floor DDL, and the DDL needs no stronger lock, so a concurrent put or
delete waits for `protect/1` instead of deadlocking with it: a write that was open before the
lock is seen by the scan, and a write that arrives later waits and then gets the floor's result.
`protect/1` therefore blocks reads and writes of both tables while it runs, for about as long as
the scan takes (an operator Need: run it in a maintenance window, or accept the pause; a request
that waits longer than its `statement_timeout_ms` while `protect/1` holds the locks returns
`unavailable` for a read or `indeterminate` for a write; a read may be retried after the
migration, and an `indeterminate` write follows the indeterminate rule in the results paragraph
at the end of [Deleting a source](#deleting-a-source), never as an unguarded replay). It reads every distinct tenant ID in pages of 1,000 and decides with the same rule as
the scoped calls on the UTF-8 values that Postgrex receives, so the database encoding does not
change the decision (an SQL_ASCII database was checked once by a local probe, not by a committed
test: the test role cannot create databases). This needs the migration's own transaction (Ecto's
default) under READ COMMITTED; without a transaction `LOCK TABLE` fails and nothing changes.

With the option, `put_source`, `delete_source/4`, `query/2` and `query_text/2` run their whole
transaction through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`; a tenant
that fails its scope rule (1..128 bytes, no C0 or C1 control character) is `invalid_request`
before any query. The caller-transaction refusal comes first, as before. `transact/3` takes no
options, so the store checks the connection out with `repo.checkout/2` and the deadline
`statement_timeout_ms + 2000` before it calls `transact/3`: the binding's 1..60000 ms holds
under the floor, not the Repo's `:timeout`. `transact/3`'s `BEGIN` and `COMMIT` are not
`log: false`, so the Repo's logger may print those two statements (no parameters). `verify/1` runs
`Elzoo.TenantIsolation.verify/3` over the vector table, then the delete-mark table, and returns
`:ok` or the first `{:error, reason}`; a binding without the option is
`{:error, :invalid_request}`. The host calls it before serving: a binding is a plain value
with no process, so no operation knows it is the first.

Minimum grants for the application role under the floor: `USAGE` on both schemas, `SELECT` on
`elzoo_search_indexes`, `SELECT, INSERT, DELETE` on the vector table, `SELECT, INSERT, UPDATE` on
the delete-mark table, and the PUBLIC defaults the floor needs: `CONNECT` and `TEMP` on the
database (`verify/3` needs `TEMP` for its rebuild) and `EXECUTE` on the reader
`elzoo_tenant_id()`, the one reader the floor calls without a space column; nothing else.
The tenant-isolation limits apply: the table owner can turn forcing off or drop the policies,
and a superuser or `BYPASSRLS` role ignores them. The prefix-local declaration registry is
deployment-wide and not under row security.

## Later options kept open

Each is reached only through a key no current caller passes: a `match` request key (trigram
similarity, with its own `pg_trgm` provider task); a `schema` member of `text_search` and an
ANN declaration member (each a new index identity); a per-query configuration key; a fusion
helper over the shared `item_id`; a snippet request key that adds a candidate key; a `spaces`
member of `tenant_isolation` for an index with a space column. Declaration, request, option,
result and candidate maps may gain optional keys and reason sets may gain members; match on
the keys and members you use.

## Bounds and transaction limits

- Source: 1..65536 chunks, at most 1 MiB each and 8 MiB total content.
- Query: k 1..256, at most 256 permitted source references, total result bytes 1..8 MiB;
  lexical text 1..4096 bytes.
- IDs: 1..1024 UTF-8 bytes without control characters; index identity 1..256.
- Versions: 1..2^31-1; offsets/times 0..2^53-1; digests exactly 32 raw bytes.
- Fixed binding statement timeout: default 5000 ms,1..60000 ms. Query can narrow it.
- No lazy streams, hot index reconfiguration or implicit truncation.

Calls from a process already inside an explicit transaction on the same Repo
refuse invalid_request before SQL. Nested Ecto transactions could otherwise
report success before an outer COMMIT. Detection is per process; raw BEGIN
outside Ecto is not detected, and calls in another process use another connection.
Sandbox savepoint release is not evidence of a durable COMMIT; consumer tests
using Sandbox must not interpret these replies as independent durable commits.

## Operations and evidence

Telemetry is inherited from ecto_sql; query metadata can include vectors,
contents, lexical query text, tenants and source lists (under the floor, also
tenant-isolation's `set_config` of the tenant). Consumers own telemetry handling and parameter privacy.
Elzoo disables SQL log output of its own statements (see the floor's `BEGIN`/`COMMIT` above)
and returns finite errors, adds no telemetry event.
Config is supported at binding creation and per call with the bounds above.
Control is not applicable: no Elzoo process or lifecycle; consumer owns Repo.

Finite real PostgreSQL/vector tests live with this Piece (`search_data_test.exs` for the
cosine store, `search_data_text_test.exs` for the ELZ-331 cases, including the floor as the
ELZ-285 application role named by `ELZOO_TEST_APP_ROLE`, which must be set), including source-copy
execution through the aggregate consumer. Tests cover the installed extension
being unavailable through a second Repo's restricted search_path, with actual
SQL casts and production operations. Literal absence from pg_extension is not
integration-tested; the namespace capability boundary is the claimed scenario.
PostgreSQL transactions/storage and pgvector distance/encoding are upstream
contracts, not local proofs. No Cure proof, disk/fsync guarantee, cross-index
search, permissions authority, embedding quality or source authenticity is claimed.

## Changes

- ELZ-416 (2026-11-26): the server this Piece states and is tested on moves from
  PostgreSQL 16 to PostgreSQL 19 (pgvector stays 0.8.x); its tests now require a
  PostgreSQL 19 server. A host on an older server upgrades to PostgreSQL 19
  before taking this revision. No code or API change; the tsquery error codes
  named for 16.15 and 16.16 stay as recorded observations.
