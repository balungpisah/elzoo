# ELZ-082 independent final review

Reviewer: independent Codex reviewer, role reviewer-082.
Reviewed SHA: `7094d8f88ee9a6494815323ab54bb443d6004044`.
Comparison base: `cf639a669bb99b7f23eba9c0077183f83e6fd8e6`.
Contract: live issue #160 and its approved early-review F1/F2 dispositions.

## Verdict

Approve the reviewed implementation and its bounded claims. No blocking code
findings. This is not merge readiness: the required serialized local class-X
full check, PR publication and exact-head hosted consumer/full checks are still
pending in the work record. Do not substitute this review or targeted tests
for those commands. New behavioral fixes need review of their changed range.

## Inspected behavior and evidence

- SQL query predicates bind both tenant and allowed_sources in the SELECT
  before cosine ordering and LIMIT. Inputs are parameters, generated/prefix
  identifiers are quoted, dimensions are validated integers. Stable tie order
  uses source C collation/version/chunk index. Empty permission sets return
  no rows. Whole selected-list byte overflow rolls back to invalid_request,
  without a smaller partial candidate list. S2 deliberately stores a closer
  forbidden source and another tenant; S5 checks whole-list refusal.
- Source replacement holds a transaction-scoped advisory lock keyed by an
  unambiguous deterministic encoding of prefix/index/tenant/source, covering
  initially absent rows too. DELETE and all INSERTs share Repo.transaction.
  COMMIT is observed by the outer transaction result before committed is
  returned. S8 pauses a writer at an INSERT trigger after DELETE and checks
  the old source remains visible, then checks all new rows; subsequent
  concurrent source replacements leave one complete version. This is finite
  transaction evidence, not a proof of durability or all concurrency schedules.
- Installation serializes registry creation per prefix with a transaction
  advisory lock, records the complete declaration, refuses mismatches and
  prevents shared physical names through uniqueness. Writes/reads recheck
  the declaration. Consumer trusted schemas/DDL are explicit Needs. Existing
  hostile or externally altered tables are not claimed to be authenticated.
- The availability query checks pg_extension membership of the visible vector
  type, plus extension ownership/visibility of its cosine operator. It does
  not accept an unrelated visible type merely because vector is installed.
  The production casts/operator use the same Repo search-path semantics.
  S9 uses an actual separate Repo with per-connection restricted search_path,
  checks installed-but-unresolved type, actual undefined_object cast, public
  install/write/query extension_missing replies and a normal-Repo control.
  It also tests a same-named unrelated domain. The README/manifest/work record
  accurately distinguish this from literal absent-catalog-entry evidence.
- Input checks cover the exact five-field Descriptor, finite float32-range
  vectors, actual length and fixed unit-norm tolerance, and provider/model
  Provenance agreement. Source-global dense chunk indices are independent
  of batch-local embedding indices, resolving early F1. S1 joins real
  text-chunker output to multiple batch-local index0 records and verifies
  durable descriptor/provenance/batch-index/vector fields. Caller-owned
  association and frozen-source authenticity remain explicit assumptions.
- Content hashes/offset-length and first/source ordering are checked; raw
  source digest is caller supplied. Stored metadata is non-null with identity
  constraints. Count/content/vector/query/time bounds are finite; float32
  storage conversion is explicit, with no bitwise-double preservation claim.
  Version replacement is intentionally not a monotonic-version policy.
- Explicit same-process caller Ecto transactions refuse before SQL. Sandbox
  savepoint/raw-BEGIN/per-process limitations are documented. Expected local
  validation/capability failures use the published refusal vocabulary;
  unexpected write/transaction failures conservatively return indeterminate
  unavailable. Read failures never return partial candidates or raw DB terms.
  S7 exercises a real locked-table timeout and transaction refusal. It does
  not establish a newly tested lost-COMMIT-observation scenario.
- Retrieved identity binds source/version/chunk index; candidates restate the
  caller permission snapshot without making permission decisions. S3 projects
  auxiliary fields away, adds actual context-selection estimate/priority and
  provenance/current check, and verifies a newer denied check yields
  access_denied. No current permission is inferred from retrieval alone.
- pgvector0.4.2 is adopted unchanged, with its Postgrex types and float32
  encoding rather than a new vector implementation. mix.lock adds only that
  package; optional Nx is not selected. Provider license/version and source
  manifests are consistent. Repo/types and tests reside in the copied Piece
  closure; actual copied-consumer execution still requires the pending checks.
- Independently inspected the retained targeted-test log and its SHA-256:
  PostgreSQL16/vector0.8.7,10 tests passed. Both retained negative-control
  logs match the recorded hashes and show the designated runtime assertions
  failing for removal of permission filtering and transaction protection.
  The failed initial mutation compilation is accurately excluded from runtime
  evidence. This review did not independently reproduce those mutations.

## Nonblocking scope note

Registry JSON serialization also changes fourteen unrelated phase strings
from escaped Unicode to literal arrows. Parsed values are unchanged. Prefer
restoring those unrelated byte changes before publication to keep ownership
scoped; this is mechanical and does not require another code review.

## Reviewer checks and limits

`git diff --check cf639a6..7094d8f` exit0.
`python3 scripts/check-roadmap.py --live` exit0: live Contracts match,
generated views agree and local links pass.

Read-only actual source/test/manifest/dependency and retained-evidence review.
No new Mix run, DB mutation, provider call, Cure proof or hosted acceptance
was produced. The10-case suite and mutation observations are finite evidence.
Full root and copied-consumer checks, independent review publication, merge
acceptance and cleanup remain coordinator responsibilities.
