# state/artifact

Tenant-owned, versioned artifact *references* in the ready Store
(`state/event-log`, `integration/sql`) whose bytes live in the ready
`integration/object-store` Piece (ELZ-096). The Piece owns identity,
versioning, integrity verification, recorded access terms, expiry and
retention; it does not own byte transport (`Elzoo.ObjectStore` does) or
policy evaluation (the consumer and `domain/authorization` do). Upload and
reference commit are two explicit phases because object storage and
database writes are not implicitly atomic.

## Copy and providers

Select `state/artifact` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without `Elzoo.Application`. See
[consuming](../../../docs/consuming.md). Piece dependencies:
`state/event-log`, `integration/sql`, `integration/object-store`,
`integration/crypto` (recipe). Providers: `cure`, `jason`, `ecto_sql`,
`postgrex`, `req`, `req_s3`, `telemetry`, `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled tables run without
`Cure.Compiler`.

## Use

```elixir
# the consumer's fold carries the artifact kinds; schema_version 1 stays in versions
fold = %{fold | kinds: Map.merge(fold.kinds, Elzoo.Artifact.kinds())}

{:ok, art} =
  Elzoo.Artifact.new(
    store: store,                       # the ready Store term {module, opts}; its own fold/limits
    object_store: object_store_config,  # %Elzoo.ObjectStore.Config{} — credentials are its injected Need
    clock: fn -> System.os_time(:millisecond) end,   # or {:manual, pid} in tests
    max_bytes: 16_777_216, max_metadata_bytes: 4_096, staging_ttl_ms: 3_600_000
  )

caller = %{tenant: "acme", principal: "worker-1", scopes: ["read", "write"]}

{:ok, %{record: rec}} =
  Elzoo.Artifact.put(art, caller, "report-42", %{
    bytes: pdf, media_type: "application/pdf",
    access: %{tenant: "acme", principals: ["alice"], scopes: ["read"]},
    access_expires_at: :never, retain_until: 1_900_000_000_000
  })

{:ok, %{bytes: pdf, record: rec}} = Elzoo.Artifact.get(art, caller, "report-42", :head)
{:ok, %{record: head}} = Elzoo.Artifact.head(art, caller, "report-42")
{:ok, %{entries: page, cursor: next}} = Elzoo.Artifact.list(art, caller, 20, nil)
{:ok, versions} = Elzoo.Artifact.versions(art, caller, "report-42")
{:ok, %{record: staged}} = Elzoo.Artifact.stage(art, caller, "report-42", input)
{:ok, %{record: committed}} = Elzoo.Artifact.commit(art, caller, "report-42", 2)
{:ok, %{record: _, object: outcome}} = Elzoo.Artifact.delete(art, caller, "report-42", 1)
{:ok, %{reaped: vs, object: results}} = Elzoo.Artifact.reap(art, caller, "report-42")
{:ok, %{record: rec, object: observation}} = Elzoo.Artifact.status(art, caller, %{artifact_id: "report-42", version: 2})
```

**Contract-arity note:** the issue lists operations as `stage/3`,
`commit/3`, `abort/2`, `put/4`, `new_version/4`, `head/3`, `get/3`,
`list/3`, `versions/2`, `delete/3`, `reap/2`, `status/2`. The consistent
reading used here counts the Piece handle plus subject arguments and treats
`caller` as the uniform presented argument (every operation presents a
caller): `stage(art, caller, artifact_id, input)`, `commit(art, caller,
artifact_id, version)`, `abort(art, caller, %{artifact_id, version})`,
`put(art, caller, artifact_id, input, opts \\ [])`, `new_version(art,
caller, artifact_id, input, opts \\ [])`, `head(art, caller, artifact_id,
opts \\ [])`, `get(art, caller, artifact_id, version)` (`:head` or an
integer), `list(art, caller, limit, cursor)`, `versions(art, caller,
artifact_id)`, `delete(art, caller, artifact_id, version)`, `reap(art,
caller, artifact_id)`, `status(art, caller, %{artifact_id, version})`.

## Records and layout

One Store stream `artifact/<tenant>/<artifact_id>` per artifact holds
self-contained `:non_state_bearing` records under head-revision CAS:
`artifact_staged`, `artifact_committed` and `artifact_deleted` each carry
the *full* version record plus its resulting `state`/`state_at`, so any
single surviving row rebuilds its version whole — Store prefix retention
cannot orphan a marker into a lost version. A second stream
`artifact-index/<tenant>` holds `artifact_index` entries appended
best-effort on every `stage` and deduplicated at read.

An artifact version record is
`%{artifact_id, version, tenant, sha256, hash_format, object_sha256,
size_bytes, media_type, object_key, access, created_at, state_at,
access_expires_at_unix_ms | :never, retain_until_unix_ms | :never,
metadata, upload, state}` with `state ∈ {:staging, :committed, :deleted}`;
the artifact's head is its highest `committed` non-`deleted` version.
`upload ∈ {:committed, :uncertain}` records whether the staging `put` was
observed committed or reported `unknown` (resolved by verification, never
blind re-put). `access` is `%{tenant, principals: [..] | :any, scopes:
[..] | :any}` with `tenant == record.tenant`. `object_sha256` is the
transport checksum (hex SHA-256 of the raw bytes) used to verify object
evidence on `commit`; it is disclosed record data, not part of the
Contract's record shape.

**No cross-stream transaction.** The tenant index and per-artifact streams
commit separately; index consistency with commits is best-effort and `list`
can miss or lag a just-committed artifact — documented, never hidden. A
Store `{:conflict, _}` maps to `{:error, {:commit_failed, %{expected,
observed}}}`; the losing commit changes nothing. An indeterminate Store
write is `{:error, {:commit_failed, :indeterminate}}` — possibly committed;
`status` (or the ready Store's `confirm/5` by nonce) reconciles.

## Content hash and object keys

`sha256 = SHA-256(<<hash_format::8, bytes>>)` (hex). `hash_format` is a
declared positive integer `1..255` stamped per record (v1 canonical form =
the raw bytes); verification always uses the record's stored format and a
format change is a declared migration — new records write the new format
and old records verify under theirs, never silent reinterpretation.
`:crypto.hash(:sha256, _)` per the ready `integration/crypto` recipe (OTP
directly; no wrapper, no new dependency).

Object keys are content-addressed and tenant-scoped:
`artifacts/<tenant>/<artifact_id>/v<version>/<sha256>`. `tenant` and
`artifact_id` are validated to a safe segment charset (alphanumerics plus
`-_.`, no `/`, never `.`/`..`, 1..64 bytes) **before** key or stream
construction.

## Access, expiry and results

Every operation presents `caller = %{tenant, principal, scopes}` —
consumer-vouched attribution, not authentication (`state/lease` precedent).
Read paths (`head`, `get`, `list`, `versions`, `status`) enforce the
recorded terms and `access_expires_at` through the law-covered pure table
(deny before expiry); mutating operations (`stage`, `commit`, `abort`,
`delete`, `reap`) require `caller.tenant == record.tenant`, which the
tenant-scoped stream makes structural — plus the recorded terms for
`delete`. A content hash never grants access. Cross-tenant `artifact_id`
lookup returns `:not_found`, never `:access_denied`.

**Appending to an artifact with a committed head enforces that head's
recorded terms.** `new_version` checks the gate before staging anything;
`commit` re-checks it before every `staging → committed` transition, so a
caller denied by the current head cannot append a new head through `put`,
`new_version` or a manual `stage`+`commit`. With no committed head there is
no access face yet — appends follow the base tenant rule and the first
commit establishes the face. A caller who passes the head's terms may
declare the new version's `access` freely: narrowing or widening is the
caller's own declaration (widening policy beyond the recorded terms is
consumer-owned; the identity is vouched, not authenticated). `stage`
itself stays tenant-scoped — a staging record never becomes a head without
passing the gate, and it expires through `staging_ttl_ms`/`reap`.

`versions` enforces the head's (or latest record's) terms first, then
filters *each* returned record by its own recorded terms and expiry —
versions the caller may not access are omitted entirely, the same rule
`list` applies to denied heads; their terms, keys and metadata are never
disclosed.

Results: `{:ok, value}` or `{:error, reason}` with `reason ∈ :not_found |
:access_denied | :expired | :deleted | :too_large | :invalid | {:invalid,
field} | {:integrity_mismatch, info} | {:commit_failed, info} |
:staging_expired | :store_unavailable | :caller_transaction |
{:store_damaged, info} | {:object_store_refused, reason} |
{:object_store_absent} | {:object_store_unknown, reason}`. Object-store
`unknown` outcomes are never converted to absent and never blind-retried;
`reconcile_put`/`commit` resolves them by verification.

`{:store_damaged, info}` is the fail-closed answer to unreadable persisted
state: `info` is `:incomplete_prefix` when Store prefix retention left a
detectable gap in `1..max_version` coverage (versions allocate contiguously
and the self-contained rows keep every surviving version whole, so a fully
retained version is the only loss shape and it always leaves a gap), or
`%{count, first}` naming the earliest fold diagnostic
(`{:unreadable, seq}`, `{:inconsistent_version, v}`,
`{:illegal_transition, v}`) when an artifact or index row cannot be
decoded, disagrees with its version's immutable fields or breaks a legal
state edge. Reads, staging, version allocation and `list` treat damaged
state as a typed failure — never as absent, never as a valid filtered
page.

`new_version` requires at least one recorded version (any state) of the
artifact, else `:not_found`; `put` allocates `max_version + 1` (`v1` for a
new artifact). `delete` applies to committed versions, `abort` to staging
— a wrong state is `{:error, {:invalid, :state}}`. `reap` is caller-driven
only: records past `access_expires_at` or `retain_until`, and staging past
`staging_ttl_ms`, move to `:deleted` and their bytes are deleted
best-effort and reported. Every already-`:deleted` version's bytes are
then deletion-attempted again under `cleanup` in the result — the durable
`:deleted` state is the tracked obligation, so a `:refused`/`:unknown`
object delete on `abort`/`delete`/`reap` is retried by the next `reap`
(`:absent`/`:deleted` confirms cleanup, `:refused`/`:unknown` stays
honestly pending); there is no background process. `media_type` is a
bounded opaque tag (UTF-8, no NUL, ≤ 256 bytes, default
`application/octet-stream`).

## Operations and limits

- telemetry: **supported** — declared in-bundle family `[:elzoo, :artifact,
  staged | committed | deleted | integrity_failure]` with bounded
  measurements (`size_bytes`, `version`) and metadata (`tenant`,
  `artifact_id`, `upload`/`cause`/`object`/`via` atoms); no bytes, keys,
  credentials or hashes in events. See `Elzoo.Artifact.Telemetry`.
- config: **supported** — construction-time bindings and bounds
  (`max_bytes`, `max_metadata_bytes`, `staging_ttl_ms`, `hash_format`,
  `object_opts`); a change is a new value, no hot reconfiguration.
- control: **supported** — `delete`, `reap` and `abort` are recorded
  durable state transitions with applied/refused/failed results; no pause
  or drain claims.
- Data classification: artifact bytes are consumer data — never logged and
  never in results, errors, inspect values or events; metadata (ids,
  hashes, sizes, terms) may appear.

Limits: no atomic object+record commit (impossible across the two
boundaries — staging/orphan states are the honest answer and `status`
exposes them); no presigned-URL lifecycle management, malware scanning,
streaming upload (single-shot `put`), cross-store replication or
cross-tenant sharing; the tenant index is best-effort; Store prefix
retention is tolerated only through the self-contained rows — a version
whose every row was retained is undetectable except as a `1..max_version`
gap, which fails closed as `{:store_damaged, :incomplete_prefix}` rather
than risking version-number reuse; `list` propagates any storage or
damage failure as an error — a storage failure never looks like a valid
filtered page; Memory is volatile test evidence only; PostgreSQL
durability/fsync is the provider's contract; `list` pages re-read the
index stream (bounded per call by index size).

## Evidence and grounding

- `cure/elzoo/artifact.cure`: 17 laws over the access-decision and
  state-transition tables (access: A1–A8; transitions: T1–T9); checked by
  the pinned Cure. The production integer comparison is finite-test-grounded
  (same scoped claim as `state/lease`).
- `test/elzoo/artifact_test.exs`: scenarios A1–A3, L1–L18 on the volatile
  Memory Store, the disposable MinIO (`ELZOO_TEST_S3_*`, fail closed) and
  loopback stubs — construction/segment/bounds validation, roundtrip,
  cross-tenant `:not_found`, recorded-terms denial, expiry, integrity
  mismatch, absent-evidence commit refusal, unknown-put staging, staging
  expiry, abort/delete/reap, list, hash-format migration, credential-free
  values, telemetry events, pure-table agreement.
- `test/elzoo/artifact_postgres_test.exs`: P1–P4 on the ready PostgreSQL
  Store (`ELZOO_TEST_DATABASE_URL`, fail closed) — durable lifecycle, CAS
  conflict mapping, ordinary Store rows, caller-transaction refusal.
- Upstream: `Elzoo.ObjectStore` finite results and checksum contract;
  `:crypto` SHA-256; the ready Store's CAS and transaction boundary;
  Jason encoding; `telemetry` synchronous `execute/3`.
