# ELZ-082 bounded-read fix: independent narrow review

Reviewer: independent Codex reviewer, role reviewer-082.
Reviewed SHA: `e125294f9cf2fc02a3a226c40bd340891ca0b6ad`.
Compared committed range: `70addb1..e125294`. Source inspection used committed
Git objects, not any temporary mutation in the writer's working tree.
PR #176, automated finding4521967484 and evidence-precision finding4521967657.

## Verdict

Approve. No blocking findings in the bounded-read implementation or the
revised evidence claims. The required new affected gate and exact-head hosted
full run remain pending; the earlier full check is baseline evidence only
after this runtime correction. No dependency/configuration/toolchain pin
changed in this range, so this fix alone does not require a new local full run.

## Inspected implementation

- The MATERIALIZED ranked CTE selects only source/version/chunk identity,
  octet length and distance, with the original tenant and permitted-source
  predicates before deterministic distance/source/version/chunk ordering and
  LIMIT k. It does not select chunk content into the result sent to the Repo.
- MATERIALIZED sized totals all selected content sizes; admitted is empty
  when the entire list exceeds the request limit. A content join is emitted
  only for admitted identities. The join includes tenant plus every remaining
  primary-key component (source_ref,version,chunk_index), so a permitted
  identity cannot join another tenant or duplicate through a missing key.
  Both scans occur in one statement/snapshot, preserving atomic old-or-new
  replacement semantics and avoiding a race between a size query and fetch.
- Overflow yields one explicitly typed sentinel with nil content and true
  overflow. Public decoding rolls back to invalid_request with no candidates.
  Normal rows have false overflow and the candidate decoder requires that
  shape. Empty ranked input has total0, no admitted rows and no overflow
  marker, correctly yielding an empty success. The <= comparison admits an
  exact-bound result; > emits overflow only, preserving whole-list refusal.
- The final ordering restores the same distance/source C collation/version/
  chunk-index ordering after the UNION. No ranking/permission/limit weakening
  or truncation into a smaller list was introduced. Sum is bigint; the finite
  k and per-chunk ceiling are well below its range.
- README and grounding claims now concern selected content crossing the
  Repo/Postgrex boundary, not a universal BEAM heap, wire-overhead or server
  execution-memory bound. PostgreSQL may still scan/process more data; the
  code and wording do not claim otherwise.

## Tests and negative control

- S11 inserts nine1MiB sources through the actual store and observes actual
  Repo query results via Ecto's query telemetry. The first call selects all
  nine under a1-byte budget, requires the sentinel and zero transferred
  content. An exact8MiB budget admits eight1MiB rows; one byte less sends
  zero content. The observer filters the specific ranked statement and
  records its driver result, rather than merely rechecking the public error.
- Independently read the retained11-test passing log and the runtime negative
  control. The mutant restores post-fetch client-side refusal while preserving
  the public invalid_request result. S11 then fails specifically on observed
  transferred bytes:9437184 rather than0. This establishes that the new test
  distinguishes receive-bound enforcement from an identical late public
  refusal; it is an executed assertion failure, not compilation failure.
- The mutation wrapper restores source SHA-256
  `403c5f1e6fa6d333e230a7404da0b6c9ea67f3e49d0d299e38b3b72e08437d0c`,
  independently matched to the reviewed committed source bytes. No mutant is
  present in the reviewed commit. This review did not rerun the mutation.
- The test observer's telemetry provider is explicitly declared. Its existing
  root pin and provider registry are unchanged; copied tests now declare the
  extra direct observer dependency instead of relying on an accidental module
  in the root project. There is no new production telemetry emitter.
- S1's comment and manifest claim accurately describe real TextChunking output
  joined with fixture ELZ-080-shaped batch-local records. They no longer claim
  execution of embedding-interface/provider calls. The fixture still checks
  the source-global versus batch-local index distinction.

## Reviewer checks and limits

`git diff --check 70addb1..e125294` exit0. Committed comparison confirms no
change to mix.exs, mix.lock, config or registry/providers.json in this round.
Read-only actual SQL/test/metadata and retained-log review; no Mix suite,
provider call, database operation or hosted acceptance was performed here.
The coordinator must confirm the writer's new gate, independent review
publication and exact-head full hosted evidence before merge.
