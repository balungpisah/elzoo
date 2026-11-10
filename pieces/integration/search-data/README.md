# integration/search-data

A PostgreSQL/pgvector store for bounded, permission-scoped chunk retrieval.
Consumers own their Ecto Repo, Postgrex types module, schema deployment, access
snapshot and final context-selection call. The store never calls an embedding
provider or decides permission. Exact cosine search only, without an ANN index.

## Installation and Needs

Copy this Piece and its declared dependency closure. Add the pinned providers
listed in piece.json, including pgvector 0.4.2 (MIT), and configure the consumer Repo:

```elixir
Postgrex.Types.define(MyApp.Types,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(), [])
# Consumer Repo configuration: types: MyApp.Types
```

PostgreSQL 16 with pgvector 0.8.x is an operator-provided Need. Its extension-owned
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
prevents two declared identities from sharing a physical table.

Every store operation checks the persisted declaration again. A binding cannot
silently switch the model/dimension/normalization of an existing index. The five
fields must exactly match Elzoo.AiEmbedding.Descriptor.compatible?/2. Dimensions
are 1..16000 (pgvector's storage bound, not an ANN-index bound); this slice accepts
only float32 and unit_l2_verified cosine vectors. Actual vector length, finite
float32 range, unit norm tolerance 1.0e-3 and provider/model provenance are checked.
Pgvector encodes vectors as float32, so Elixir double-precision input values are
rounded for storage; bitwise preservation of input doubles is not promised.

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
row identity and provenance. Concurrent successful replacements are serialized;
there is no monotonic-version or latest-version policy. A later writer can
replace a higher version with a lower one when the caller requests it.

Returns `{:committed, count}`, `{:refused, reason}`, or
`{:indeterminate, :unavailable}`. Refusal reasons are invalid_request,
invalid_chunk, source_too_large, incompatible_embedding and extension_missing.
No partial-source success is returned. Conservative indeterminate covers lost
COMMIT observation and other unexpected DB errors; retry/reconciliation policy
belongs to the caller. The store does not claim external exactly-once Effects.

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
or ranking quality. A whole selected list over the content-byte bound returns
`{:error,:invalid_request}` with no rows, rather than changing ranking or returning
a smaller partial list. Other read errors are unavailable, incompatible_embedding
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

## Bounds and transaction limits

- Source: 1..65536 chunks, at most 1 MiB each and 8 MiB total content.
- Query: k 1..256, at most 256 permitted source references, total result bytes 1..8 MiB.
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
contents and source lists. Consumers own telemetry handling and parameter privacy.
Elzoo disables SQL log output and returns finite errors, adds no telemetry event.
Config is supported at binding creation and per call with the bounds above.
Control is not applicable: no Elzoo process or lifecycle; consumer owns Repo.

Finite real PostgreSQL/vector tests live with this Piece, including source-copy
execution through the aggregate consumer. Tests cover the installed extension
being unavailable through a second Repo's restricted search_path, with actual
SQL casts and production operations. Literal absence from pg_extension is not
integration-tested; the namespace capability boundary is the claimed scenario.
PostgreSQL transactions/storage and pgvector distance/encoding are upstream
contracts, not local proofs. No Cure proof, disk/fsync guarantee, cross-index
search, permissions authority, embedding quality or source authenticity is claimed.
