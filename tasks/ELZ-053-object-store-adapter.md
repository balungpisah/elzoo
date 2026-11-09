# ELZ-053 — Specify the S3-only object-store Adapter on MinIO

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/object-store
- Dependencies: ELZ-011, ELZ-023
- CI prerequisite: the disposable S3 test server (#112) is on main.

## Outcome

Own an Adapter that performs put, get, head, list and delete of objects and issues
presigned URLs against one S3-compatible endpoint (MinIO on the owner's host), with every
key-addressed operation naming bucket, key and backing store, every list naming bucket,
backing store and an explicit prefix, and every write outcome reported as
committed, refused or unknown. Adopt `req_s3` 0.2.5 (Apache-2.0) on the pinned Req; fall
back to `ex_aws_s3` 2.5.9 only if multipart upload is required by the first caller and
`req_s3` cannot do it. This is the second task of the owner's batch (decision record:
`docs/plans/catalogue-dispositions.md#integration-object-store`; owner answer 2 and product
fact 1: S3-only caller, option A, no Jido VFS).

## Admission record

1. **Responsibility and caller.** Translate object operations to S3 requests and S3
   results to typed outcomes. Callers: C8 upload and transform (store the uploaded bytes and
   the transform result), C2 report artifact; `state/artifact` (deferred) is the first owned
   consumer and supplies content ownership, integrity and retention policy.
2. **Interface and invariant.** Inputs: an endpoint and bucket binding (Need), an
   operation `{put | get | head | list | delete | presign}` with key, bounded body or body
   stream, declared content type, optional content SHA-256, and a deadline; the ELZ-011
   Effect declaration and the ELZ-023 intent record for dispatched writes. Outputs:
   `committed{etag, bytes}`, `found{metadata, body}`, `absent`, `listed{keys, truncated,
   continuation}`, `refused{denied | no_such_bucket | precondition_failed | too_large |
   invalid_key | checksum_mismatch | invalid_request | credentials_unavailable}`
   (`checksum_mismatch`: the provider's `XAmzContentChecksumMismatch` or `BadDigest`
   response, or a binary body that does not match the declared SHA-256 before dispatch;
   `invalid_request`: a local argument check before dispatch, such as page size, prefix or
   continuation; `credentials_unavailable`: the injected credential Need failed before any
   connection was opened), `unknown{reason}` for a
   write whose response was not observed, and the
   ELZ-011 delivery-result mapping. Invariants: every key-addressed operation names bucket,
   key and the backing-store identity, and every list names bucket, backing-store identity
   and an explicit prefix (the empty prefix allowed); a put is committed only when the
   provider response carries the expected checksum; a delete is committed when the
   provider returns 204, which acknowledges the delete request, not that an object
   previously existed or that absence persists; a timeout after dispatch is `unknown`,
   never `absent`; list results are bounded and continuation is explicit; the Adapter
   never hides a local/remote interchange; the secret access key never appears in any
   Adapter result, error, inspect value, Adapter log or Adapter event; the access-key ID
   is an identifier that can occur in a returned presigned URL and in signed
   upstream-request metadata; a presigned URL is a bearer capability, redacted from
   inspect values and errors and never emitted by the Adapter; consumer-installed
   upstream (Req/Finch) telemetry handlers may see signed request headers, and their
   collection and redaction are the consumer's responsibility.
   Non-goals: content ownership, versioning policy, retention, cross-store atomicity,
   public ACLs, lifecycle rules.
3. **Reuse check.** `req_s3` 0.2.5 on the pinned Req is the smallest client; verify by
   exercise that it supports presign, list continuation and the checksum headers the
   Contract needs; `ex_aws_s3` 2.5.9 (MIT) only for multipart if required; Jido VFS is not
   adopted. Elzoo owns the typed outcome mapping, the unknown-outcome rule and the binding
   to the ELZ-011/023 Effect and intent boundaries.
4. **Split test.** Request translation and outcome classification stay in one Adapter;
   content identity and retention are `state/artifact`'s. A streaming body boundary is
   `delivery/data-stream`'s and is used, not redefined.
5. **Failure and evidence.** Dangerous paths: an interrupted upload reported as committed;
   a denied or missing bucket reported as absent object; a checksum mismatch accepted; an
   unbounded list; a secret access key or a presigned URL in an Adapter log line or event;
   a write retried blindly after
   an unknown outcome. Proofs: none required; the outcome mapping is a finite table checked
   by tests. Tests against a real MinIO instance: in CI the backend job provisions a pinned MinIO
   server binary by SHA-256 inside the job container, starts it with a disposable bucket and
   credentials and exports `ELZOO_TEST_S3_URL` (CI task ELZ-064); the test binding fails
   closed when that variable is absent, exactly like `ELZOO_TEST_DATABASE_URL`; no owner
   MinIO credential is ever used in CI. Scenarios: put
   and get round trip with checksum; denied bucket; missing object; list pagination with
   a small page size; too-large body refused before dispatch; interrupted upload (connection
   dropped mid-body) reported unknown and reconciled by head; presign expiry; absence of
   the secret access key from every Adapter result, error, inspect value, log and event,
   and of presigned URLs from Adapter logs and events. Upstream: S3 API semantics and
   MinIO durability are
   provider contracts, named not proved.
6. **Composition record.** Depends on `core/effect`, `delivery/effect-intent`,
   `integration/http` (ready); `integration/secrets` is deferred, so the endpoint
   credentials are an explicit injected Need (configuration reference, never a literal in
   source) reviewed in this Contract; the record's disagreement note names this choice.
   Telemetry `inherited` from the ELZ-052 family if merged first, otherwise `planned`;
   Config `supported` for endpoint, bucket, size bound, page size and deadline; Control
   `not_applicable`. No durability claim beyond the provider's.

## Scope

- add `pieces/integration/object-store/` with the Adapter, outcome schema, README,
  `piece.json`, tests and a MinIO test binding through `ELZOO_TEST_S3_URL` (fail closed);
  until ELZ-064 is merged the worker may develop against the owner's MinIO locally, but
  no PR is queued before ELZ-064 is on main;
- add `req_s3` as a dependency at 0.2.5 and record it in `registry/providers.json`
  (and `ex_aws_s3` only if multipart is shown to be required, with the reason recorded);
- decide and record the size bound, page size and presign expiry defaults with the first
  caller's requirements;
- promote `integration/object-store` in its own catalogue row and release-plan entry,
  regenerate `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Round trip, denied, missing, paginated list, too-large, interrupted upload and
      presign scenarios pass against the CI-provisioned MinIO endpoint (ELZ-064), and
      fail closed without `ELZOO_TEST_S3_URL`; no owner credential appears in CI.
- [ ] A timeout after dispatch is reported `unknown` and never `absent` or `committed`.
- [ ] The secret access key appears in no Adapter result, error, inspect value, log or
      Adapter telemetry metadata, and a presigned URL in no Adapter log or event, with a
      test; consumer-installed upstream (Req/Finch) telemetry handlers are a stated limit.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests against one MinIO endpoint on the owner's host; upstream contracts for the S3
API, `req_s3` and MinIO; no proof is claimed. Loopback or LAN only; no TLS certification,
no cross-region, no versioning, no retention, no content ownership.

## Out of scope

Artifact ownership and retention (`state/artifact`), streaming engine, multipart unless
required, local filesystem backend, Jido VFS.

## Reference

Decision record `integration/object-store` (ADOPT; owner answer 2, product fact 1);
ranking R18; awesome-elixir report rows `req_s3`, `ex_aws_s3`; disagreement note on the
`integration/secrets` prerequisite.
