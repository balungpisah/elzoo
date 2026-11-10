# ELZ-096 — Specify the owned artifact reference store over object storage

- Phase: demand-led state policy
- Catalogue IDs: state/artifact
- Dependencies: ELZ-009, ELZ-013, ELZ-033, ELZ-053

## Outcome

Deliver `state/artifact`: tenant-owned, versioned artifact *references* in the
ready Store whose bytes live in the ready `integration/object-store` Piece.
The Piece owns identity, versioning, integrity verification, declared access
terms, expiry and retention; it does not own byte transport (object-store does)
or policy evaluation (domain/authorization and the consumer do). Upload and
reference commit are two explicit phases because object storage and database
writes are not implicitly atomic.

## Decisions this task carries

- Reconciled dependencies (RC-13 listed ELZ-033, ELZ-009, ELZ-024, RC-05):
  - `ELZ-024` (`domain/authorization`) is **not** a dependency. That Piece
    evaluates ALLOW/ASK/DENY policy; this Piece enforces the access terms
    *recorded on each artifact reference* (tenant match, optional principal
    allowlist, optional required scopes, access expiry). A consumer needing
    richer policy runs authorization before calling; the recorded-terms check
    is the durable last line and needs no authorization code.
  - `RC-05` (secrets) is **not** a dependency. `integration/object-store`
    already resolves its S3 credentials through an injected per-call Need;
    this Piece inherits that shape through its object-store binding and stores
    no credential material.
  - `ELZ-009` (ready Store: `state/event-log` + `integration/sql`) and
    `ELZ-053` (ready `integration/object-store`) are added explicitly; RC-13's
    `state/event-log` dependency and its object-store path are now merged.
- Owner decision OD-F1: object store is MinIO through the S3 API, S3-only
  caller, `req_s3` first — already realized by `integration/object-store`;
  this Piece consumes its public API and Contract only.
- Owner answer 5 (OD-Q5): the first audited mutation was the ELZ-023
  effect-intent record; artifact reference commits are ordinary Store writes
  in this slice — audit-log composition is a later consumer concern.
- Content hash follows the catalogue note's ruling (ELZ-025 study): SHA-256
  over a **versioned canonical encoding** — the preimage is
  `<<hash_format::8, bytes::binary>>` where `hash_format` is a declared
  positive integer starting at 1 (v1 canonical form = the raw bytes) and is
  stored on the record. `:crypto.hash(:sha256, preimage)` per the ready
  `integration/crypto` recipe (OTP directly; no new dependency, no wrapper).
  Verification always uses the record's stored `hash_format`; a format
  change introduces a new `hash_format` value — a declared migration, never
  silent reinterpretation of old records.
- Object keys are content-addressed and tenant-scoped:
  `artifacts/<tenant>/<artifact_id>/v<version>/<sha256>` — a repeated put of
  identical bytes targets the same key, which makes dispatch-unknown recovery
  verifiable instead of retryable. `tenant` and `artifact_id` are validated
  to a declared safe segment charset (alphanumerics plus `-_.`, no `/`, no
  `.`/`..` segments, bounded length) before key construction, because
  `Elzoo.ObjectStore` refuses `/`, `.` and `..` key segments and unsafe
  segments could collide prefixes across tenants.

## Admission record

1. **Responsibility and caller.** Own the versioned reference lifecycle:
   stage bytes, commit the reference, verify integrity on read, enforce
   recorded access terms, expire and reap. Callers (RC-13): C2 report
   artifact, C6 agent results, C7 retained digest, C8 upload and transform.
   `integration/object-store` remains the byte Adapter; `state/event-log` /
   `integration/sql` remain the durable boundary; `delivery/effect-intent`
   discipline applies inside object-store, not re-implemented here.
2. **Interface and invariant.**
   - *Construction.* `new/1` takes a Store binding (the ready Store's
     PostgreSQL boundary; the ready in-memory variant for tests where it
     offers one), an `Elzoo.ObjectStore` binding (carrying its own credential
     Need), a clock port, and bounds (`max_bytes`, `max_metadata_bytes`,
     `staging_ttl_ms`). No environment reads; no root Application.
   - *Records.* An artifact version record is
     `%{artifact_id, version, tenant, sha256, hash_format, size_bytes,
     media_type, object_key, access, created_at_unix_ms,
     access_expires_at_unix_ms | :never, retain_until_unix_ms | :never,
     state}` with `state ∈ {:staging, :committed, :deleted}` — state is
     per `(artifact_id, version)`; the artifact's head is its highest
     `committed` non-`deleted` version. `access` is
     `%{tenant, principals: [..] | :any, scopes: [..] | :any}` where
     `tenant` must equal the record tenant. Versions are immutable;
     `version` starts at 1 and increments per `artifact_id`.
   - *Persistence.* Records persist through the ready Store boundary; the
     builder selects the layout (for example a per-artifact stream of
     version records under head-revision CAS, or the `state/lease`-style
     direct-table adapter if the `integration/sql` boundary supports it —
     a reviewed coupling) and must state its limits: there is no
     cross-stream/cross-table transaction, so tenant indexes and expiry
     sweeps are separate records whose consistency with commits is
     best-effort and documented; Store `{:conflict, _}` maps to a typed
     conflict result, never silent overwrite.
   - *Operations.* `stage/3` (validate size/metadata bounds, hash bytes,
     `ObjectStore.put` under the content-addressed key → staging record or
     typed failure), `commit/3` (Store write flipping staging → committed;
     verifies object presence and size/hash evidence before writing),
     `abort/2` (staging → deleted + best-effort object delete), `put/4`
     (stage+commit convenience), `new_version/4` (same as `put` on an existing
     `artifact_id`, version = max+1), `head/3`, `get/3` (downloads bytes and
     recomputes SHA-256 before returning them), `list/3` (tenant-scoped,
     bounded, cursor), `versions/2`, `delete/3`, `reap/2` (expires records
     past `access_expires_at`/`retain_until` and best-effort deletes bytes),
     `status/2`. Every operation presents a caller
     `%{tenant, principal, scopes}`; `head`/`get`/`list`/`versions`/
     `delete`/`new_version` enforce `access` plus `access_expires_at`.
     Mutating operations (`stage`, `commit`, `abort`, `delete`, `reap`)
     additionally require `caller.tenant` to equal the record's tenant —
     the presented identity is consumer-vouched attribution, not
     authentication (the `state/lease` precedent: owner strings are
     attribution); authority beyond tenant match is consumer-owned policy.
   - *Invariants.* A content hash never grants access: every read path checks
     the recorded access terms and expiry against the presented caller.
     Cross-tenant `artifact_id` lookup returns `:not_found`, never
     `:access_denied` (no existence leak). Integrity mismatch on `get` is a
     typed `{:error, {:integrity_mismatch, ..}}`, never served bytes. Object
     store and Store writes are not atomic: `commit` is the reference-commit
     boundary; bytes may exist before it (staging) and may outlive a deleted
     record until `reap`/best-effort delete completes — both states are
     recorded, never hidden. Each `artifact_id` has at most one committed
     head version.
   - *Failure taxonomy.* Typed results only: `:not_found`, `:access_denied`,
     `:expired`, `:deleted`, `:too_large`, `:invalid`,
     `{:integrity_mismatch, _}`, `:commit_failed` (including the Store
     `{:conflict, _}` CAS mapping — the losing commit changes nothing),
     `:staging_expired`, `:store_unavailable`, and object-store's finite
     outcomes mapped through (`:refused`, `:unknown` after dispatch —
     resolved by `head`/reconcile verification on the next
     `commit`/`status`/`reconcile_put`, never by blind re-put). Cleanup
     after `abort`/`delete`/`reap` is best-effort and reported, not
     guaranteed.
3. **Reuse check.** `integration/object-store` (ready, ELZ-053) owns all S3
   mechanics including finite committed/found/absent/refused/unknown results,
   checksum verification and bounded list continuation; `state/event-log` +
   `integration/sql` (ready, ELZ-009) own durable records and transactions;
   `:crypto` (OTP) owns SHA-256 per the ready `integration/crypto` recipe.
   No new upstream dependency. No second byte store, no presign surface in
   this slice (object-store's `presign` stays available to consumers; stale
   access URLs are handled by `access_expires_at`, not URL expiry).
4. **Split test.** Reference lifecycle, access enforcement, integrity
   verification and retention share the "record is source of truth, bytes are
   verified" invariant and stay together. Byte transport, hashing primitive
   and durable storage are already separate ready Pieces.
5. **Failure and evidence.** Dangerous paths (RC-13 acceptance): partial
   upload (put `unknown` → staging persists, `commit` verifies via `head`,
   `status` exposes it); wrong hash (tampered or wrong bytes →
   `integrity_mismatch` on `get`, staging rejected on `commit` when evidence
   disagrees); stale access (past `access_expires_at` → `:expired`); retention
   expiry (`retain_until` → `reap` deletes bytes, record marked); cross-tenant
   lookup (`:not_found`); failed reference commit (object exists, record does
   not → orphan staging, honest `status`, `reap`/`abort` reconcile);
   object-store `unknown` after dispatch (never converted to absent, never
   blind-retried). Proofs/tests: pure access/expiry/integrity decisions; Store
   scenarios on the ready boundary; object-store exercised through its own
   test support (MinIO fixture) or loopback stubs — no live provider spend.
6. **Composition record.** Piece dependencies: `state/event-log`,
   `integration/sql` (ELZ-009), `integration/crypto` (ELZ-013 recipe),
   `integration/object-store` (ELZ-053). Needs: Store (PostgreSQL),
   object-store binding (S3 endpoint/bucket/region/credentials — inherited
   Needs, resolved per call by the consumer's binding), clock. Telemetry:
   `supported` — bounded commit/stage/delete/reap/integrity-failure events,
   no byte content; readiness ships the event tests. Config: `supported` at
   construction (bounds, `staging_ttl_ms`, bindings). Control: `supported` —
   `delete`, `reap` and `abort` are recorded durable state transitions;
   no hot reconfiguration, pause or drain claims. Data classification:
   artifact bytes are consumer data — never logged; metadata (ids, hashes,
   sizes, terms) may appear in telemetry.

## Scope

- add `pieces/state/artifact/` with README, `piece.json`, `lib/`, `cure/`
  (if a pure decision earns it), `test/` and examples; pure access/expiry/
  integrity decisions in Cure where they are decisions, Elixir for Store and
  object-store calls;
- publication duties on the task branch (main's publication step already
  created the issue): create `tasks/ELZ-096-state-artifact.md` byte-equal to
  the live issue body; add release-plan job `ELZ-096` (paths, dependencies,
  `issue_body_sha256` of the live body, outputs `["state/artifact"]`, plus
  `kind`/`release`/`stage`/`product_aims` carried from RC-13 —
  P01,P05,P06,P07,P08,P11,P12); move the `state/artifact` entry's `job` from
  `RC-13` to `ELZ-096` and mark RC-13 superseded for this output (as
  RC-10/RC-19 were for ELZ-055/ELZ-054); regenerate `LEDGER.md` and roadmap
  views (`mix elzoo.ledger` after metadata changes);
- at readiness: registry row, `piece.json` manifest hashes, operational
  declarations, consumer-layout test;
- run `mix elzoo.ledger` after metadata changes; worker gate
  `mix check --affected origin/main` + `mix test pieces/state/artifact/test`
  before every push; full local `mix check` only if dependencies/config
  change (none expected — no new Hex dependency).

## Acceptance

- [ ] `stage`/`commit`/`abort`/`put`/`new_version`/`head`/`get`/`list`/
      `versions`/`delete`/`reap`/`status` behave per the Interface record on
      the ready Store and a stub or MinIO-backed object-store.
- [ ] RC-13 scenarios pass: partial upload cleanup, wrong hash →
      `integrity_mismatch`, stale access URL → `:expired`, retention expiry →
      reaped, cross-tenant lookup → `:not_found`, failed reference commit →
      honest staging status; integrity verified on `get` under the declared
      format.
- [ ] Access terms enforced on every read path; `access_expires_at` and
      `retain_until` are explicit (`:never` allowed, must be declared);
      hash alone never grants access (tested); mutating ops require tenant
      match; unsafe `tenant`/`artifact_id` segments refused before key
      construction.
- [ ] Content hash is SHA-256 over the versioned canonical preimage
      (`<<hash_format, bytes>>`); `hash_format` stored per record; a second
      format version verifies old records under their stored format
      (declared migration, tested).
- [ ] Object-store `unknown` outcomes are never converted to absent and never
      blind-retried; `reconcile_put`/`commit` resolves them by verification.
- [ ] No credential, secret or consumer byte content in results, errors,
      inspect values, logs or events (tested); the Piece reads no
      environment variables.
- [ ] Operational applicability declared per docs/operational-contracts.md.
- [ ] Piece tests pass in the exported consumer layout; the root Application
      is not required.
- [ ] Full hosted `symbolic-check.yml` green on the exact PR head; local
      worker gate recorded with exit codes.

## Evidence and limits

Finite tests over the listed scenarios against the ready Store and
object-store (MinIO fixture or loopback stubs); pure tests of access, expiry
and integrity decisions; upstream contracts of S3 semantics via
`integration/object-store`, OTP `:crypto`, and the ready Store's transaction
boundary. No claim of atomic object+record commit (impossible across the two
boundaries — staging/orphan states are the honest answer), no presigned-URL
lifecycle management, no malware scanning, no cross-Store replication, no
streaming upload (object-store `put` is single-shot in this slice).

## Out of scope

Multipart/resumable upload, presign issuance policy, antivirus/content
scanning, encryption at rest beyond what the object store provides,
cross-tenant sharing or public links, audit-log composition, artifact
processing/transformation pipelines, UI.

## Reference

RC-13 contract and acceptance ("Separate provider byte-storage translation
from tenant-owned versioned artifact references … a hash never grants
access"); `docs/plans/catalogue-dispositions.md#state-artifact`;
`integration/object-store` README/piece.json (finite results, credential
Need); `state/lease` README (Store transaction and fencing precedent);
owner decisions OD-F1, OD-Q5; ELZ-025 study ("no denials" ≠ "denial record
unreadable" — applied here as "no bytes" ≠ "bytes unreadable").

## Open questions (none blocks a builder)

1. Whether `media_type` is a free-form string validated against a declared
   set or an opaque tag; the builder records the choice and tests it.
2. Whether `reap` runs on a caller-driven schedule only (recommended: yes —
   no background process is implied by this Piece) or exposes a tick the
   consumer wires; recorded in the README either way.
