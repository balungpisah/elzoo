# ELZ-053 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `a5a85e23fa5ea9bf2ab7980ad78da5b10f74e830`

Inputs read: live issue #109; `docs/work/ELZ-053.md`; `docs/work/ELZ-053-provider-probe.exs`; the diff from `origin/main`; `docs/plans/catalogue-dispositions.md`; `AGENTS.md`; operational, capability, change-class and CI guidance; ready `core/effect`, `delivery/effect-intent` and `integration/http` sources; and the working-tree sources of `req_s3`, `req` and Finch. No Mix command or probe was run.

1. **blocking — Contract reading: Inputs, outputs and issue #109 Admission record 2.** The issue's invariant says every operation names bucket, key and backing store. The proposal makes `list` take `prefix`, and list results carry `prefix`, not `key`. That is an intentional and sensible list interface, but it does not meet the current live Contract. Amend the issue before implementation to say that key-addressed operations name bucket, key and store, while `list` names bucket, store and an explicit prefix (including the empty prefix); make that exact distinction in the Piece Contract, README, result schemas and tests.

2. **blocking — Contract reading lines 130-133, 161-163, 237-239 and 255-258.** A4 says the access-key ID appears “only inside a presigned URL.” That is false under the proposed dependency: `req_s3` signs ordinary requests, and a consumer-attached Finch/Req upstream telemetry handler can receive signed request metadata including an Authorization header. Moreover, the presigned URL is itself a returned bearer capability, so the access-key ID necessarily appears in a result. Replace the absolute credential wording with a defined distinction: the secret access key never appears in any Adapter result, error, inspect value, Adapter log or Adapter event; the access-key ID is an identifier that can occur in a returned presigned URL and signed upstream-request metadata; the presigned URL is a bearer capability and is redacted from inspect/errors and never emitted by the Adapter. State that consumer-installed upstream telemetry handlers may see signed request headers and that their collection/redaction is a consumer responsibility; test Adapter-owned observations separately from that upstream limit. Do not claim an access-key ID is absent from all telemetry.

3. **blocking — Evidence plan S7, lines 232-234.** An interrupted upload is deliberately classified `unknown`; therefore a subsequent `head` cannot honestly be required to be `absent`. The provider may have committed the object before the client observed the response. Test that the first result is unknown and that an explicit reconciliation reports either absence or a found object whose declared integrity can be compared with the intended write; do not turn reconciliation into proof of no effect.

4. **should-fix — Proposed A3, lines 126-129 and 157-160.** A3 is necessary: S3 DELETE can return 204 without an ETag or checksum, so the current universal write invariant cannot include delete. Its proposed replacement overstates the result by saying 204 “states that no object remains”; concurrent writes and provider durability are outside this Piece, and versioning is expressly not owned. Use: “a put is committed only when the provider response carries the expected checksum; a delete is committed when the provider returns 204. That acknowledges the delete request, not that an object previously existed or that absence persists.” Keep the unversioned-bucket assumption explicit and upstream.

5. **should-fix — Inputs line 81, outputs lines 88-102, Evidence S5 line 230.** `page_size > max_page_size` is said to be refused before dispatch, but no output tag represents invalid page size or continuation/prefix validation. `refused{invalid_key}` is not an honest substitute. Add a narrow local `refused{invalid_request}` (or a specifically named `invalid_page_size`) and its delivery mapping, or reject construction/call arguments before the operation exists and state that API shape precisely. Exercise it with the no-request stub.

6. **should-fix — Proposed A1/A2 lines 148-156.** A1 is useful and honest if scoped to the named MinIO/S3 response codes and separately tested for a local binary-body mismatch; it gives the checksum dangerous path a meaningful result. A2 is not necessary for issue #109: the existing `unknown{transport}` is conservative and honest. A connection-refused or DNS error alone is not a general proof that no request byte reached transport, while `delivery/effect-intent` requires a true no-send attestation for `not_dispatched`. Prefer no A2. If the coordinator needs `unavailable`, define a narrow, independently attested local pre-dispatch condition and test that attestation, rather than infer it from a transport exception.

7. **should-fix — Contract reading lines 48-54 and R4 lines 134-137.** “Each call … at most one HTTP request” conflicts with the non-MinIO HEAD-404 fallback, which may send a second request. The parenthetical makes the intent understandable but not a stable operation bound. State “one request normally; HEAD may issue one documented bucket-HEAD disambiguation request when the provider omits an error code,” and list this as an unverified other-provider assumption because only the pinned MinIO behavior is exercised.

8. **should-fix — ELZ-023 composition lines 267-274 and Q1.** The task Contract names ELZ-023 and its intent record for dispatched writes, whereas the proposal has neither a production Binding nor a Piece dependency edge and delegates the sole Binding to test code. That can be a valid split only after an exact live-Contract amendment: object-store owns outcome translation/reconciliation evidence; a consumer-owned Binding owns effect-intent identity, authentication and durable intent. Otherwise ship the declared dependency and a production boundary. A generic shipped Binding is likely the wrong answer because `Elzoo.EffectIntent.Binding` requires a concrete provider account, operation, identity and attestation policy that belong to the consumer. Do not describe a test-only Binding as satisfying a production dependency without amending the Contract and manifest rationale.

9. **note — Provider verification and scope.** `req_s3` 0.2.5 source supports the proposed `s3://` GET/PUT path translation, regular Req HEAD/DELETE requests after attachment, XML decoding for bucket GET/listing, parameters needed for ListObjectsV2, and `ReqS3.presign_url/1` with explicit method/endpoint/credentials/region. It has no S3 Multipart Upload API; its documented multipart-form helper is not multipart object upload. It does not implement checksum policy itself, but supplied headers traverse Req, so checksum/If-None-Match claims remain provider tests rather than library guarantees. Explicit supplied options win over its environment fallbacks in the inspected source, but the adapter must pass every credential, endpoint and region value on every request and presign call. The probe is useful upstream evidence but is not an executable test and its results are not independently reproduced here.

10. **note — Evidence and operational record.** The evidence plan correctly separates no proof, type/contract checks, tests, monitored behavior, upstream contracts and assumptions; it also fixes initial size, page and expiry limits, states no versioning/retention, bounds pagination, maps denied/missing bucket separately, and uses the pinned disposable MinIO variables fail-closed. Retain local loopback stubs only for deterministic no-dispatch/transport classification; provider semantics must remain covered against the pinned MinIO server. The final Piece must declare `telemetry`, `config` and `control` in `piece.json`; `config: supported` needs named in-bundle test evidence, while `telemetry: planned` must not promise a custom event. The proposed no-global-config credential Need and same-PR `req_s3` departure are consistent with the recorded coordinator direction, subject to one local full `mix setup && mix check` after the dependency change and no `config/` change.

## Amendment review

### A1

Recommendation: accept, with the narrower MinIO/S3-code scope described in finding 6. It is necessary to make a provider checksum rejection distinct from a precondition conflict and is honest only as a tested provider mapping, not a universal S3 proof. The displayed “Before” is not byte-exact against the live body: the issue has a physical line break between `|` and `invalid_key`; the proposal replaces it with a space.

### A2

Recommendation: reject for now; retain `unknown{transport}`. The task does not require a definite no-send result, and the proposed evidence does not establish it generally enough for effect-intent's attestation rule. Its displayed before/after shares the A1 non-byte-exact line-wrap defect; it is also one combined amendment, not independently reviewable exact text.

### A3

Recommendation: accept after narrowing as in finding 4. It is necessary because DELETE 204 cannot satisfy the existing ETag/checksum condition; the current wording is too strong about durable/persistent absence. The quoted Before is not byte-exact: issue #109 has the sentence wrapped after “the” and before “provider,” whereas the proposal normalizes it.

### A4

Recommendation: replace, not accept as written. An access-key ID is properly an identifier rather than the secret access material, but the current live word “credentials” includes the injected pair and therefore forbids it until the issue is deliberately amended; a presigned URL is also a bearer capability. The quoted Before is byte-exact as a contiguous sentence fragment, but it omits the issue's surrounding physical line context; the proposed After is false because it omits upstream signed-request telemetry. Use the replacement text in finding 2 and scope S11 to Adapter-owned result/error/inspect/log/event and Adapter telemetry, with a separate documented upstream-telemetry limit.

## Questions

### Q1

Recommendation: do not ship a generic production Binding; amend the task and manifest to remove the direct ELZ-023 Piece dependency if outcome translation is the only reusable object-store responsibility. Otherwise a real dependency edge and production integration are required. A test-only Binding is useful evidence but is not a production composition boundary.

### Q2

Recommendation: distinguish secret material from the access-key ID, but do not describe the ID as invisible. Treat the ID as an identifier and the full presigned URL as a bearer capability; never emit either from Adapter-owned logs/telemetry and redact URL inspect/error forms. Document that consumer-installed upstream Finch/Req telemetry handlers can observe signed headers, including the Authorization representation containing the identifier; do not claim those handlers are controlled by this Piece.

### Q3

Recommendation: accept A1 with scope, replace A3, decline A2, and accept the numeric defaults only as first-caller configuration defaults rather than universal S3 limits. The 64 MiB default and 5 GiB maximum must retain the stated no-multipart limit; 100/1000 pages and 900/3600 seconds are bounded Config choices with tests, while S3's broader expiry limit remains upstream.

### Q4

Recommendation: agree that no new Cure source is needed. This is an effectful provider translation and finite outcome classification, for which named MinIO and stub tests plus the existing Effect/Envelope validation are appropriate; no Cure proof should be implied.

## Verdict

Proceed after fixes. There are three blocking Contract/evidence corrections before implementation: reconcile the list-key invariant with the live issue, replace A4 with an honest identifier/bearer-capability and upstream-telemetry boundary, and make interrupted-upload reconciliation accept the outcome that unknown deliberately preserves.
