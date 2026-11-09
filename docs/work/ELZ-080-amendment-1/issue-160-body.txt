# ELZ-082 — Specify the permission-scoped pgvector chunk store behind a consumer Repo

- Phase: demand-led retrieval slice
- Catalogue IDs: integration/search-data (RC-18's output moves here; first retrieval provider: pgvector)
- Dependencies: ELZ-030, ELZ-080, ELZ-081
- CI prerequisite: the pgvector database service (ELZ-084) is on main.

## Outcome

Own a store that writes chunk records (from ELZ-081) together with their embeddings (from
ELZ-080) into PostgreSQL through a consumer-owned Ecto Repo with the `vector` extension,
and answers one bounded similarity query whose results are already scoped to the caller's
tenant and an explicit, caller-supplied set of permitted sources, returned as retrieval
candidates that the caller completes into `workflow/context-selection` candidates, so
selection re-checks current access before anything reaches a model. Adopt `pgvector` 0.4.2 (MIT) for the Ecto and Postgrex types;
Elzoo owns the table shape, the embedding-compatibility rule, the scoping filter, the
bounds and the outcome table. This is the pgvector slice of the owner's retrieval order
(decision record: `docs/plans/catalogue-dispositions.md#integration-search-data`; owner
decision 2026-11-09, 23:45 WIB: "pgvector with OpenAI embeddings; embeddings are a
provider-neutral class so we can add more sources").

## Admission record

1. **Responsibility and caller.** Persist and retrieve chunk embeddings for one index.
   Callers: C7 scoped context retrieval (`workflow/context-selection` consumes the
   results); C6 agent delegation later through the same selection step.
2. **Interface and invariant.** Inputs: a binding (consumer Repo module, optional
   prefix, index identity) as a Need; an index declaration fixed at creation:
   embedding provider, model id, dimensions, dtype, required normalization and distance
   metric (cosine first, which requires `normalization: unit_l2_verified` vectors from
   `integration/ai-embedding`); each declaration owns one table (one fixed-dimension
   `vector(n)` column) per `{index_identity, dimensions, metric}`, created by the
   migration helper, and a second declaration of the same index identity with a
   different dimension, model or metric is refused; row identity is unique on
   `{tenant, source_ref, version, chunk_index}`; writes `put_source(binding, tenant, source, chunks)` where
   `source = {source_ref, version, source_digest}` and each chunk carries ELZ-081's
   `{index, start_byte, end_byte, content, content_digest}` plus one ELZ-080 embedding
   record; reads `query(binding, request)` with `tenant`, `query_embedding` (an ELZ-080
   record), `k`, `allowed_sources` (the caller's permitted `source_ref` list from its
   access snapshot), `principal` and `checked_at`. Outputs: writes return
   `committed{chunks}`, `refused{incompatible_embedding | invalid_chunk |
   source_too_large | invalid_request | extension_missing}` or
   `indeterminate{reason}` when the commit outcome was not observed (the
   `integration/sql` vocabulary); reads return `{:ok, [retrieval_candidate]}` (at most
   `k`, ordered
   by distance, ties by `source_ref`, `version`, chunk `index`) or `{:error,
   :unavailable | :invalid_request | :incompatible_embedding | :extension_missing}`,
   never a partial list. A `retrieval_candidate` is not yet a complete
   `workflow/context-selection` candidate: it carries `item_id` (stable chunk identity
   derived from `source_ref`, `version` and chunk `index`), `version`, `source`
   (= `source_ref`), `content`, `content_hash` (= `content_digest`), `derived_from: []`
   and `access: %{principal, checked_at, result: :allowed}` restating the caller's own
   snapshot, plus `distance`, `source_digest`, `start_byte`, `end_byte`; the caller
   adds `estimate` and `priority` (selection's required fields,
   `pieces/workflow/context-selection/README.md` "Inputs and Needs"), the provenance
   nodes and the current access context before calling `select/2`. Invariants:
   a row is returned only when its tenant equals the request tenant and its `source_ref`
   is in `allowed_sources` (enforced in the SQL `WHERE`, not after fetching); an empty
   `allowed_sources` returns no rows; a query or write whose embedding provider, model,
   dimensions or normalization differs from the index declaration is refused; results
   are bounded by `k` (at most 256, the context-selection candidate bound) and by total
   content bytes (at most 8 MiB, each chunk at most 1 MiB); `put_source` deletes every
   row of `{tenant, source_ref}` and inserts the new version's rows in one transaction,
   so a reader sees the old version or the new one, never a mix; a vector whose
   descriptor is not compatible with the declaration (including `normalization: none`
   for a cosine index) is refused `incompatible_embedding`; every stored row has non-null provenance (source ref, version,
   digest, offsets, embedding provenance). The store does not call ELZ-080: its
   indexing caller groups chunks into one ELZ-080 call only while that call's
   canonical command payload fits ELZ-080's 1..65,536-byte bound (a chunk whose text
   alone exceeds it cannot be embedded, so it cannot be indexed in this slice), and it
   handles an ELZ-080 refusal or unknown outcome itself, writing no partial source. The store never decides permission: the
   `access` it returns only restates the caller's snapshot, and context-selection's
   current check still applies. Non-goals: ranking quality, hybrid or keyword search,
   re-ranking, ANN tuning, cross-index search, source ownership and retention
   (`state/artifact`, deferred), embedding calls (ELZ-080), deletion policy.
3. **Reuse check.** `pgvector` 0.4.2 (MIT; depends on `postgrex`, optional `ecto`, both
   already locked; no new transitive package) supplies `Pgvector.Ecto.Vector`, the
   Postgrex extensions (`Pgvector.extensions/0`, `lib/pgvector.ex:157-163`) and the
   distance macros (`cosine_distance`, `l2_distance`, `max_inner_product`,
   `lib/pgvector/ecto/query.ex:10-55`). It requires the consumer's Repo to use a
   Postgrex types module built with `Postgrex.Types.define/3` that includes
   `Pgvector.extensions()` (package README, "Ecto"). The server extension (pgvector
   0.8.x, PostgreSQL License) is an operator-installed Need provided in CI by ELZ-084.
   The consumer-Repo, prefix and caller-transaction conventions follow the ready
   `integration/sql`. No new database client, no vector library of our own.
4. **Split test.** Chunking (pure, ELZ-081) and embedding (external Effect with cost,
   ELZ-080) stay separate; this Piece owns only persistence and scoped retrieval.
   Permission decisions stay with the caller's access snapshot and
   `workflow/context-selection`.
5. **Failure and evidence.** Dangerous paths (RC-18 acceptance list plus store paths):
   a row of another tenant or of a non-permitted source returned; access revoked between
   retrieval and selection still reaching the model; a stale source version returned
   after re-indexing; an oversized chunk or result; missing provenance; a provider
   (database) timeout returning partial results; an embedding of another model or
   dimension compared silently; the extension missing at runtime. Proofs: none
   required. Tests against the CI PostgreSQL with `vector` (ELZ-084), failing closed
   without `ELZOO_TEST_DATABASE_URL` or without the extension: round trip of a source
   with chunks; tenant isolation; `allowed_sources` filtering including the empty list;
   revocation between retrieval and selection (retrieval candidates completed by the
   test as a caller would, then fed to `Elzoo.ContextSelection.select/2` with a current
   check that now denies one source, which is dropped with `access_denied`); a second
   index declaration with another dimension refused; a non-unit vector refused for the
   cosine index; re-index replaces the old version atomically
   (a concurrent reader sees one version); incompatible embedding refused for write and
   query; `k` and byte bounds; statement timeout returns `unavailable` with no rows;
   extension missing returns `extension_missing`; ordering and tie-break are stable.
   Upstream: PostgreSQL transactions and pgvector distance operators are named, not
   proved; exact (sequential) search is used in this slice, so top-k is exact for the
   stored rows.
6. **Composition record.** Piece dependencies: `workflow/context-selection` (result
   shape and the revocation test), `integration/ai-embedding` (ELZ-080) for the embedding
   descriptor type, ELZ-081's chunk
   record type. Needs: the consumer's Ecto Repo with a Postgrex types module including
   `Pgvector.extensions()`; PostgreSQL 16 with the `vector` extension created by an
   operator (superuser, because the extension is not marked trusted); a migration helper
   creates the table and indexes but never creates the extension; optional SQL prefix.
   No credential of its own (the Repo's connection is the consumer's). Telemetry
   `inherited` from `ecto_sql` (the consumer Repo's query events; their metadata can
   include query parameters such as the query vector and the permitted source list, and
   handling them is the consumer's responsibility); Elzoo adds no events. Config
   `supported` (index declaration at creation; per-call `k`, byte bound and statement
   timeout with ceilings; no hot reconfiguration). Control `not_applicable` (no process;
   the consumer owns the Repo lifecycle). No durability claim beyond PostgreSQL's.

## Scope

- add `pieces/integration/search-data/` with the store module, migration helper, README,
  `piece.json`, tests and a test-only Repo and Postgrex types module under the Piece's
  own `test/support` (the exported consumer layout must find them there);
- add `pgvector` 0.4.2 as a dependency, recorded in `registry/providers.json` with its
  license, plus the server extension as a recorded Need; `mix.exs`/`mix.lock` change,
  so one local full `mix setup && mix check` runs at the head (class X rule);
- promote `integration/search-data` with coverage `subset` in its catalogue row; RC-18's
  output is moved to this task at publication and RC-18 marked superseded, as RC-10 and
  RC-19 were for ELZ-055 and ELZ-054 (main's publication step); regenerate `LEDGER.md`
  and the roadmap views.

## Acceptance

- [ ] Round trip, tenant isolation, permitted-source filtering, revocation between
      retrieval and selection, atomic re-index, incompatible embedding, bounds, timeout
      and missing-extension scenarios pass against the CI database with `vector`
      (ELZ-084) and fail closed without it, including a second index declaration with a
      different dimension refused and a non-unit vector refused for the cosine index.
- [ ] Every returned row matches the request tenant and a permitted source, checked in
      SQL, with a test that a non-permitted row closer to the query is not returned.
- [ ] A composition test completes the retrieval candidates with `estimate`, `priority`,
      provenance nodes and a current access context, passes them to
      `Elzoo.ContextSelection.select/2`, and a source revoked after retrieval is dropped
      there with `access_denied`.
- [ ] The Piece's tests pass in the exported consumer layout (`check-consumers-db`).
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests against one PostgreSQL 16 server with pgvector 0.8.x; upstream contracts of
PostgreSQL, pgvector and `pgvector` 0.4.2; no proof is claimed. Retrieval relevance is not
truth or quality. Exact search only; no ANN index recall claim. The store restates, and
does not establish, permission.

## Out of scope

Embedding calls, chunking, ANN (HNSW, IVFFlat) tuning and filtered-ANN behavior, hybrid
search, re-ranking, deletion and retention policy, cross-tenant or cross-index search,
a shipped Repo or configuration.

## Reference

Decision record `integration/search-data` (ADOPT; owner answer 1; owner decision
2026-11-09); RC-18 contract and acceptance ("Revoked access between retrieval and
selection, stale source, oversized input, missing provenance and provider timeout");
`workflow/context-selection` README (candidate and access fields); `integration/sql`
README (consumer Repo conventions).

## Open questions (none blocks a builder)

1. The store relies on ELZ-080's embedding descriptor (provider, model, dimensions,
   dtype, normalization) and accepts only `dtype: float32` and
   `normalization: unit_l2_verified` for a cosine index; publish after ELZ-080.
2. ANN index: exact search in this slice (recommended); an HNSW option with a stated
   recall limit and pgvector 0.8 iterative scans for filtered queries is a later slice.
3. Chunk identity: a deterministic `item_id` from `source_ref`, `version` and chunk
   index (recommended) versus the chunk content digest (which collapses identical
   chunks across sources; context-selection already dedupes by hash).
