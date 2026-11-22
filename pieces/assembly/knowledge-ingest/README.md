# assembly/knowledge-ingest

One durable Assembly in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on
PostgreSQL 16. It takes one pinned `state/artifact` version of a tenant's document and runs it
through `integration/document-parse`, `integration/text-chunking`, `integration/ai-embedding`
(through the `delivery/effect-intent` owner) and `integration/search-data` as bounded Oban jobs
over `integration/jobs`. It keeps a durable ingest record, staged chunks and counted embedding
attempts in four Piece-owned tables under the `state/tenant-isolation` floor.

It is not a RunEngine Run, makes no exactly-once Effect claim and no claim about retrieval or
embedding quality. The parsed text is untrusted content: the Piece stores and indexes it and does
not mark it; the host marks retrieved chunks with `workflow/untrusted-content`.

## Copy and providers

Select `assembly/knowledge-ingest` with `mix elzoo.take`; the dependency-closed copy is owned by
the consuming application. Piece dependencies and claim-level grounding are in
[piece.json](piece.json). Providers: `oban` 2.24.2, `ecto_sql` 3.14.0, `postgrex` 0.22.4,
`elixir`, `otp`.

## Host composition

```elixir
# 1. Install, from a consumer Ecto migration run by the table owner, in an existing schema.
defmodule MyApp.Repo.Migrations.KnowledgeIngest do
  use Ecto.Migration
  def up, do: Elzoo.KnowledgeIngest.Migration.install("knowledge")
end

# 2. Build the config (validated once; fixed for its life).
{:ok, config} =
  Elzoo.KnowledgeIngest.new(
    repo: MyApp.Repo,                 # the Repo of the Piece tables
    prefix: "knowledge",
    oban: MyApp.Oban,                 # an Oban instance whose Repo is MyApp.Repo
    queue: "knowledge_ingest",
    search: search_binding,           # Elzoo.SearchData.new/3, with or without its floor
    artifact: artifact,               # Elzoo.Artifact.new/1
    artifact_scopes: ["read"],
    embedding: [binding: MyApp.EmbeddingBinding, provider: MyApp.Provider,
                provider_config: provider_config, credentials: &MyApp.key/0,
                models: ["text-embedding-3-small"]],   # configure/1 without tenant and sink
    request: %{model: "text-embedding-3-small"},        # optional dimensions, input_type, provider_options
    intent: %{store: durable_store, host: {Elzoo.EffectIntent.StoreHost, host_ctx},
              clock: fn -> System.os_time(:millisecond) end},
    max_attempts: 3
  )

# 3. Register the runner on this node, check the floor as the application role, then serve.
:ok = Elzoo.Jobs.register(config.queue, Elzoo.KnowledgeIngest.runner(config))
:ok = Elzoo.KnowledgeIngest.verify(config)

caller = %{tenant: "acme", actor: "svc-ingest"}   # host-vouched, never authenticated
request = %{source_ref: "handbook", version: 3,
            artifact: %{artifact_id: "handbook-pdf-text", version: 7},
            media_type: "text/markdown", chunking: []}
{:ok, %{state: :requested}} = Elzoo.KnowledgeIngest.submit(config, caller, request)
{:ok, status} = Elzoo.KnowledgeIngest.status(config, caller, %{source_ref: "handbook", version: 3})

# 4. Meter every attempt (domain/metering): ref is stable, usage nil when none was reported.
{:ok, %{entries: entries, next: next}} =
  Elzoo.KnowledgeIngest.attempts(config, caller,
    %{source_ref: "handbook", version: 3, after: nil, limit: 256})

for %{ref: ref, outcome: :completed, usage: usage} <- entries,
    do: record_usage(caller.tenant, ref, usage)

# 5. Remove a document: search-data owns the index.
{:committed, _} = Elzoo.SearchData.delete_source(search_binding, "acme", "handbook", 3)
```

`intent.allow_volatile: true` is accepted only with a Memory Store (tests). The embed step
supplies `task_supervisor` and, per attempt, the ingest's tenant and the sink
(`Elzoo.AiEmbedding.Sink.to_pid/1` of the embed step's process).

The host registers one config per queue. While any ingest of that config is not terminal, the
host keeps its `prefix`, its `search` binding, and its `embedding` binding, provider account and
`request`, so that a recovered attempt is rebuilt with its original identity and arguments (a
Need).

## Interface

No public function raises for any term in any argument, except `Migration.install/1`, which
raises `ArgumentError` with the fixed message `"invalid knowledge ingest prefix"` before any DDL
for a prefix outside `^[a-z_][a-z0-9_]{0,62}$`. Apart from `runner/1` and `verify/1`, each
returns `{:ok, value}` or `{:error, reason}`.

- `new(opts)`: exactly the keys above (`max_attempts` 1..5, default 3); `{:error, :invalid}`
  otherwise. It calls `configure/1` with a probe tenant and sink and `admission/2` of a one-input
  probe request (no intent), refuses an `embedding` whose `max_input_bytes` is below 8,000, and a
  `request` whose `model` is not the search descriptor's `model` or whose expected dimension is
  not its `dimensions`.
- `submit(config, caller, request)`: `caller` exactly `%{tenant, actor}`. `tenant` is 1..64
  bytes of `[A-Za-z0-9._-]`, never `.` or `..`; `actor` 1..128 bytes of UTF-8 without a C0 or
  C1 control. `request` exactly `%{source_ref, version, artifact: %{artifact_id, version},
  media_type, chunking}`: `source_ref` 1..1,024 bytes of UTF-8 without a C0 control or DEL;
  `version` 1..2,147,483,647; `artifact_id` under the tenant's segment rule and its `version` an
  integer ≥ 1 (`:head` is refused); `media_type` `"text/plain"`, `"text/markdown"` or
  `"text/html"`; `chunking` a keyword list of `chunk_size` (2,000..8,192, default 2,000),
  `chunk_overlap` (0..200, default 200) and `max_chunks` (1..65,536, default 4,096), each at most
  once, with `chunk_size × 4 ≤ max_input_bytes`.
- `status(config, caller, %{source_ref, version})`: `%{source_ref, version, state, reason,
  batches: %{done, total}, attempts, text_sha256, parser}`.
- `attempts(config, caller, %{source_ref, version, after, limit})`: `limit` 1..256, `after`
  `nil` or the `next` of an earlier page; entries `%{ref, batch, number, outcome, usage}` in
  `(batch, number)` order.
- `cancel/3` and `resubmit/3` on `%{source_ref, version}`.
- `runner(config)`: the `%{perform, backoff}` map for `Elzoo.Jobs.register/2`.
- `verify(config)`: `Elzoo.TenantIsolation.verify/3` over each Piece table; `:ok` or the first
  `{:error, reason}`.

Each call checks shape and bounds (`:invalid`), then `repo.in_transaction?()`
(`:in_transaction`), both before any query; then it runs through
`Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`. The first query of `submit/3`,
`cancel/3`, `resubmit/3` and of every step write refuses an isolation level other than READ
COMMITTED (`:isolation`). Errors: `:invalid`, `:in_transaction`, `:isolation`, `:conflict`,
`:not_found`, `:indexing`, `:terminal`, `:not_failed`, `:unavailable`. No error, reason, log or
job argument holds a source reference, content or vector.

### Identity and equal requests

The ingest identity is `(tenant, source_ref, version)`. The ingest ID is the lowercase hex
SHA-256 of the length-framed fields `"elzoo/knowledge-ingest/ingest/1"`, `prefix`, the search
binding's `index_identity`, `tenant`, `source_ref` and the decimal `version`, each framed as a
32-bit big-endian byte length followed by its bytes. Two configs that share one intent Store
therefore never share an attempt reference.

Two requests are equal when their canonical encoding is equal: the SHA-256 of the length-framed
fields `"elzoo/knowledge-ingest/request/1"`, `index_identity`, `tenant`, `source_ref`,
`artifact_id`, `media_type` and the decimal `version`, artifact `version`, `chunk_size`,
`chunk_overlap` and `max_chunks`, with the text-chunking defaults filled in. The `actor` is not
part of it (an equal submit by another actor returns the existing ingest; the first actor stays
recorded). Another request for the same identity is `{:error, :conflict}`.

A new identity inserts the ingest row and its prepare job in one transaction. An equal request
returns the existing ingest; when that ingest is not terminal and not `failed` and no job of its
current step is `available`, `scheduled`, `executing` or `retryable` (it was stranded), the
submit enqueues that step's job again with a new key, under the ingest row lock. An `enqueue/2`
failure rolls the transaction back and returns `{:error, :unavailable}` with nothing written.

## States

`requested`, `preparing`, `embedding`, `indexing`, `indexed`, `failed`, `cancelled`,
`superseded`; `indexed`, `cancelled` and `superseded` are terminal. `reason` is
`nil` except in `failed`: `{:artifact, a}`, `{:parse, r}`, `{:chunk, r}`, `:chunk_too_large`,
`:embedding_exhausted`, `:embedding_unknown`, `{:embedding_refused, r}`, `{:index, r}`,
`:index_mismatch` or `{:step_failed, step}`.

| From | Event | To |
| --- | --- | --- |
| (none) | `submit/3` of a new identity | `requested`, prepare job enqueued |
| `requested` | the prepare job starts | `preparing` |
| `preparing` | prepare commits its staged chunks and batches | `embedding`, batch 0's job |
| `embedding` | a batch completes and another remains | `embedding`, the next batch's job |
| `embedding` | the last batch completes | `indexing`, the index job |
| `indexing` | `put_source` committed | `indexed`, staged chunks deleted |
| `indexing` | `put_source` refused `stale_version` | `superseded`, staged chunks deleted |
| any working state | a failure | `failed`, staged chunks kept |
| `requested`, `preparing`, `embedding`, `failed` | `cancel/3` | `cancelled`, staged chunks deleted |
| `failed` | `resubmit/3` | the failed step's working state, its job with a new key |

`cancel/3` in `cancelled` returns its status again; in `indexing` it is `:indexing` (the write may
already have committed: wait for `indexed`, then `delete_source/4`); in `indexed` or `superseded`
it is `:terminal`. A cancel of an ingest that failed at its index step can leave that version
stored: remove it with `delete_source/4`. `resubmit/3` is `:terminal` in a terminal state and
`:not_failed` in any other state that is not `failed`; an embed restart gets a fresh budget of
`max_attempts` and attempt numbers continue. Versions are independent ingests; the version guard
decides which one stays indexed. `indexed` records that this version's guarded write committed,
not that it is still stored: `query/2` gives the live state.

## Steps

Each step is one `Elzoo.Jobs.Worker` job of `config.queue` (job `max_attempts` 3). Job keys are
`<tenant>/<ingest ID>/<step>[/<batch>]/<n>`, unique per enqueue; they hold no source reference,
content or vector. A job acts only in its own state (prepare: `requested` or `preparing`; the
embed job of batch b: `embedding` with b the first batch not completed; index: `indexing`):
every write takes the ingest row `FOR UPDATE` and checks that state first, and otherwise writes
nothing and completes. Every step first checks that the config's search binding has the
`index_identity` recorded at submit (else `:index_mismatch`).

1. **Prepare**: `Artifact.get/4` (`:store_unavailable` and `{:object_store_unknown, _}` are a
   job error; any other error fails at once), `DocumentParse.parse/2`, `TextChunking.chunk/4`
   with the parse result's `format`. Each chunk must fit `max_input_bytes` and its own
   one-input canonical request `max_request_bytes` (else `:chunk_too_large`); under a
   `text_search` declaration a chunk with a NUL fails `{:index, :invalid_chunk}`, before any
   paid call. Batches are greedy in chunk order within `max_inputs` and the canonical request
   bound. One transaction stores the chunks and batches, `text_sha256` and `parser`, and moves to
   `embedding` only if the ingest is still `preparing`.
2. **Embed**, one batch at a time. Attempt `n` of batch `b` has the logical request reference
   `<ingest ID>/<b>/<n>`. It is recorded `:pending` and committed before its admission, then
   dispatched through `configure/1`, `admission/2` (deadline `clock.() + receive_timeout_ms +
   10_000`), `EffectIntent.start_link/1` under the step's own `Task.Supervisor` and
   `advance(owner, :dispatch)`, waiting at most `receive_timeout_ms + 10_000` ms. The owner and
   the supervisor stop before the step returns, so a send never outlives its step. A run that
   finds the latest attempt `:pending` starts its owner without `host` (read-only, no
   admission) and classifies by `status/1`: `{:Confirmed, _}` is `:completed_lost`; `:absent`
   or `{:Intended, _, _}` is `:not_dispatched` (`:unknown` under a Memory Store); anything else
   `:unknown`. The first recorded outcome of an attempt wins. Completed writes the vectors to the
   staged chunks and enqueues the next job; throttled, overloaded, `credentials_unavailable`,
   `:not_dispatched` and `:completed_lost` snooze for a new attempt while the budget lasts (the
   provider's `retry_after` clamped to 1..3,600 s, else 5 × 2^(k−1) s after the k-th attempt of
   the budget), then `:embedding_exhausted`; an unknown outcome fails `:embedding_unknown` and
   only `resubmit/3` starts another attempt; any other refusal fails `{:embedding_refused, r}`.
3. **Index**: `put_source(search, tenant, {source_ref, version, text_sha256}, chunks, if_newer:
   true)` outside a transaction; committed moves to `indexed` and deletes the staged chunks in
   one transaction; `stale_version` to `superseded`; `{:indeterminate, :unavailable}` is a job
   error (a guarded repeat is safe); another refusal fails `{:index, r}`.

| Step | Oban job timeout | The step's own deadline | Job `max_attempts` |
| --- | --- | --- | --- |
| prepare | `:infinity` (Oban's default; the worker traps exits) | 120,000 ms | 3 |
| embed | `:infinity` | `receive_timeout_ms` + 30,000 ms (90,000 by default) | 3 |
| index | `:infinity` | 120,000 ms | 3 |

The runner runs each step in a process linked to the job's process and kills it at the
deadline, so a held transaction rolls back. A passed deadline, raise, throw, exit, failed query
or retried artifact or index error is a job error: the runner returns `{:error, reason}` and Oban
retries with a backoff of 5 s × the attempt number; on the job's last attempt the runner fails
the ingest `{:step_failed, step}` (or the step's own reason) under the own-state rule and returns
`{:cancel, reason}`. A provider attempt snoozes, which consumes no job attempt.

**Lifeline Need.** The host's Oban Lifeline `rescue_after` must exceed the largest step deadline
plus 60 s: 3 minutes with the defaults, 11.5 minutes with `receive_timeout_ms` 600,000. Oban's
default of 60 minutes meets it. Lifeline then rescues only a job whose node died.

## Grants

The application role, which must not own the tables and must not bypass row security, needs:

- `USAGE` on the `prefix` schema;
- `SELECT, INSERT, UPDATE` on `elzoo_knowledge_ingests`, `elzoo_knowledge_batches` and
  `elzoo_knowledge_attempts`, and `SELECT, INSERT, UPDATE, DELETE` on `elzoo_knowledge_chunks`;
- on Oban's jobs table in the Oban prefix, `SELECT, INSERT, UPDATE, DELETE` on `oban_jobs` and
  `USAGE` on `oban_jobs_id_seq` (Oban's own needs; the Piece inserts and reads job rows);
- the PUBLIC defaults the floor needs: `CONNECT` and `TEMP` on the database (`verify/1`) and
  `EXECUTE` on `elzoo_tenant_id()` in `prefix`;
- the grants of the search binding, the artifact store and the intent Store, as their Pieces
  state.

The tenant-isolation limits apply: the table owner can turn forcing off or drop the policies, and
a superuser or `BYPASSRLS` role ignores them.

## Grounding, operations and limits

- Tests (`test/elzoo/*.exs`) on a disposable PostgreSQL 16 with pgvector, a real Oban 2.24.2
  instance (drained, so no real backoff, snooze or wait runs, except group 6, which runs the
  queue and a short Lifeline), a scripted provider that counts its calls and a real
  `state/artifact` store over the disposable MinIO; the intent Store on `integration/sql` except
  the Memory cases. Listed scenarios pass; they are not proofs.
- Upstream: Oban 2.24.2 uniqueness, snooze (`attempt - 1`), Lifeline rescue and the `:infinity`
  timeout; PostgreSQL row locks and READ COMMITTED; the ready Contracts of the dependencies.
- Telemetry `inherited` (Oban and Ecto events; no Elzoo event). Config `supported` at
  construction only. Control `supported`: `cancel/3` and `resubmit/3`; Oban queue pause is
  inherited.

Limits: scripted providers only (no quality claim, no live provider). No exactly-once Effect: a
`:completed_lost` attempt is a second paid call, a throttle or overload may have been processed,
and an `:unknown` attempt may have been charged; the attempts record keeps that visible. With a
durable Store each admitted attempt leaves one intent whose arguments are the batch's chunk texts,
outside the tenant floor; the Piece removes none, and neither a cancel nor `delete_source/4`
removes them. Under a Memory Store an intent lasts only until a restart, and an interrupted
attempt whose intent is not found is `:unknown` even when it was never sent. Oban job rows carry
the tenant and the ingest ID, outside the floor. The step timings are observations, not
guarantees: a slower host can fail a large document `{:step_failed, :prepare}`; a version too
large to write within the search binding's `statement_timeout_ms` + 2,000 ms ends
`{:step_failed, :index}`. `new/1` checks the request's model and dimension against the index
descriptor, not its provider, so a provider mismatch is found only at the index step. A rescue of
a live embed job, which the Lifeline Need excludes, can classify its in-flight attempt as
`:unknown` or `:not_dispatched`. `indexed` is not live state. A delete that lands while a crashed
index run awaits its re-run ends the ingest `superseded`. A stranded ingest waits for an equal
`submit/3`; there is no sweeper. An older version is embedded in full before its index step finds
it stale. Batches run one at a time. The index step holds every chunk and vector of the version
in memory. A `failed` ingest keeps its staged chunks until it is cancelled, and ingest and attempt
records are never pruned. Deleted rows stay in dead tuples, WAL and backups until PostgreSQL
reclaims them. One config serves one queue and one search index. The actor and the caller are
host-vouched, not authenticated. Ingesting grants no authority and prevents no injection.
