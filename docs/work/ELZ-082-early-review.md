# ELZ-082 independent early Contract review

Reviewer: independent Codex reviewer, role reviewer-082.
Reviewed SHA: `c7537ccd10f64ce22b8a8a1f7bb5ab2f0f558df1`.
Contract: live issue #160. Reviewed plan: `docs/work/ELZ-082.md`.
Dependencies inspected: ELZ-080 Descriptor/outcome, ELZ-081 chunk contract,
ELZ-030 context-selection exact candidate keys and current-access semantics,
and integration/sql transaction boundaries. No implementation exists yet.

## Verdict

Proceed after the coordinator resolves F1 and fixes the evidence plan in F2.
Neither requires changing a ready dependency Contract. No implementation or
runtime acceptance is claimed by this review.

## Findings

**F1 — Blocking composition mismatch: embedding index is batch-local.** The
plan requires an embedding item's index to equal its chunk's index. ELZ-080
validates indices as exactly 0..batch_length-1; ELZ-081 indices are dense across
the source. The live ELZ-082 body explicitly requires grouping chunks across
multiple ELZ-080 calls to respect its 65536-byte canonical-command bound. For
source chunks32..63 in a second batch, provider indices0..31 must remain valid
ELZ-080 data, so requiring equality would reject an ordinary admitted workflow.
Keep source chunk identity separate from batch-local embedding index. The
caller joins the item selected by the input's batch position to the actual
source chunk, adding that call's shared Descriptor and Provenance unchanged.
Do not rewrite or reinterpret an ELZ-080 index as a source-global index. Add
a multiple-batch composition test in which a nonzero chunk index has
embedding.index0; retain global dense chunk-index validation independently.

**F2 — Evidence plan must name a real missing-extension boundary.** The
alternative “controlled server capability seam” is underspecified and could
produce only a mocked reply. Live acceptance calls for missing extension at
runtime, against PostgreSQL. Prefer a dedicated, guarded disposable test
database with no vector extension, using the actual production Repo/types
configuration and production availability check. Never drop the extension
from a shared database. Before implementation, the coordinator should settle
how the isolated database is provisioned on local and hosted runs without
implicit admin Needs or protected CI edits. A Repo double can supplement
translation tests but cannot alone satisfy this boundary acceptance. A
genuine server-visible capability restriction can be an alternative only if
it exercises the production detection/query path and its precise assumption
is recorded; simply substituting a boolean or error atom is insufficient.

## Decisions within the published Contract

- The caller-created per-vector input containing the original embedding item
  and shared Descriptor/Provenance is a reasonable concretization: ELZ-080's
  completed outcome separates these values. Document exact accepted keys and
  include a composition example; association is the caller's responsibility,
  while the store validates shape, compatibility and supplied provenance.
- Whole-query content-byte overflow returning invalid_request and no rows is
  consistent with the finite error vocabulary and “never a partial list.”
  Document it, test exact bound and one byte over, and avoid changing ranking
  or silently selecting fewer candidates to fit.
- Refusing calls in an explicit same-process Ecto transaction as invalid_request
  preserves the issue's result vocabulary and reuse convention. Declare this
  precondition and the per-process/raw-BEGIN/Sandbox limitations explicitly.
  A released Sandbox savepoint must never be advertised as a durable COMMIT.
- The proposed k256, 8MiB result/source-content, 1MiB chunk and 65536-chunk
  limits fit the issue and upstream inputs. Fix and publish identifier/vector
  dimension/time bounds before final review. Validate vector dimension against
  PostgreSQL vector storage limits, not an ANN index limit or the client's
  binary encoding width.

## Design and implementation requirements

- Store and compare all five descriptor fields using Descriptor.compatible?/2.
  Validate actual finite float32 vectors, dimensions and the fixed normalization
  tolerance before Pgvector.new/1; check provider/model provenance agreement.
  Document float32 storage conversion without claiming bitwise preservation of
  Elixir double-precision input values.
- Use parameter binding for values and safe identifier quoting for the trusted
  Repo prefix/generated table names. Declaration lookup, mismatch refusal and
  concurrent schema installation must share appropriate transaction/locking
  protection. Bindings are data, not authority to bypass database verification.
- Advisory-lock keys need unambiguous encoding of index/tenant/source and a
  deterministic transaction lifetime. Serialize delete-plus-insert replacements
  even for initially absent sources; enforce primary-key/non-null provenance
  independently. The paused-transaction concurrency test must show actual
  old-or-new results for one SQL snapshot, plus concurrent-writer serialization.
- Tenant and allowed_sources predicates must be in the same SQL statement as
  ordering/limit; prove the selected finite case with a forbidden closer row.
  Empty permission lists should return no rows with the documented validation
  precedence. Timeout/error translation returns no candidates and redacts raw
  DB exceptions/parameters. Conservative indeterminate write errors are honest
  when COMMIT observation is absent.
- Real context-selection test must project retrieval-only fields away, add the
  required estimate/priority/provenance nodes/current check, and show access_denied
  after revocation. Snapshot access returned by retrieval does not establish
  current authorization.
- Adopt pgvector0.4.2 unchanged. Independently read its release source: new/1
  encodes float32, to_list/1 decodes that encoding, Ecto.Vector delegates to
  Pgvector, dependencies are Postgrex plus optional Ecto/Nx. Keep Nx absent;
  consumer Repo/types and all test fixtures stay in the Piece's copied closure.
- No Cure proof is required. Real boundary tests, upstream storage/transaction
  contracts and unverified host assumptions remain separate evidence categories.
  Telemetry inherited from ecto_sql, per-call/fixed Config and no Control process
  are accurately scoped in the plan.

## Review limits

Read-only plan, dependency and primary release-source review. No Mix command,
provider call, database operation or check result was produced. Final review
must inspect actual code, negative controls, source-copy execution and both
local full class-X and exact-head hosted evidence.

## F2 clarification: real search-path capability test approved

The coordinator's proposed second Repo with a connection-level search_path
restricted to a fresh test schema and pg_catalog is an acceptable real
server-visible capability boundary. It does not test literal absence from
pg_extension. Approval is conditional on these implementation/tests:

1. Document the runtime Need as the installed pgvector extension and its vector
   type/operators usable through the Repo connection's search path; the
   production migration/casts/operators use that same unqualified resolution.
   A pg_extension catalog entry alone must not count as usable capability.
2. In the restricted Repo, establish with real SQL that the extension remains
   installed but pg_catalog.to_regtype('vector') is NULL, and an actual
   unqualified NULL::vector(n) cast fails with undefined_object. Run any
   failing SQL outside the subsequent operation's transaction, or rollback
   its aborted transaction before continuing. No mocked availability result.
3. Invoke the actual public migration/install, put_source and query paths with
   that Repo and otherwise valid inputs; each returns its documented
   extension_missing outcome, with no partial schema/source write or rows.
   Production availability checking must run on the same connection/search
   path semantics as the statements it guards. Configure every connection in
   the second Repo pool; do not SET a random checked-out connection and then
   assume the whole pool changed. Use a distinct Repo name to isolate it.
4. In the normal Repo against the same database, show the extension type is
   usable and the same valid operation succeeds. Verify neither test changes
   the extension or the normal Repo's search path. No shared DROP EXTENSION,
   operator credential, CREATEDB privilege or CI provisioning is needed.
5. Keep evidence wording exact: “installed extension unavailable through this
   Repo's search path” was integration-tested; actual catalog absence was
   not. An I/O-free result translator unit test can separately exercise an
   absent catalog result, but must remain labeled translation evidence.
6. Resolve the visible vector type to the extension's actual member type, or
   otherwise rule out a same-named unrelated type being accepted as pgvector
   when comparing availability. A trusted application-owned schema/search
   path assumption may be explicit, but no arbitrary visible type is proof
   that the required extension implementation is selected.

This satisfies the early review's allowed genuine server-visible restriction
and the runtime capability failure scenario without a new error or dependency
Contract. It does not establish literal catalog-absence integration evidence.
The coordinator should record this bounded acceptance decision rather than
claiming all missing-extension environments were tested.

Primary grounding: PostgreSQL16 documents that search_path resolution applies
to data types and operators, and removing public removes unqualified access
to its objects ([Schemas,5.9.3](https://www.postgresql.org/docs/16/ddl-schemas.html#DDL-SCHEMAS-PATH)).
It documents to_regtype returning NULL for an unresolved type name
([System information functions,9.26](https://www.postgresql.org/docs/16/functions-info.html)).
The predicted restricted-Repo behavior is an inference from those contracts
until the specified actual SQL test runs. This clarification ran no SQL or Mix.
