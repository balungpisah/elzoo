# ELZ-093 independent final implementation review

Reviewer: independent Codex reviewer, role reviewer-093-final.
Reviewed SHA: `1bb6ff61929b66b13857dfdf24ff5e50319ac097`.
Comparison base: `339c1edb6925afd324280f95c2dd7591ae1f96ee`.
Live Contract: issue #171. Early review: ELZ-093-early-review.md.

## Verdict

Approve the implementation and test design at this SHA. No blocking code findings.
Executable validation is pending, so this is not a readiness or merge-acceptance
statement. The writer must record real test/gate outcomes and the coordinator must
confirm the PR's own full exact-head hosted evidence.

## Findings and grounding

- The actual provider call installs its collector into the request before Req runs.
  On overflow bounded/2 halts before appending the incoming chunk, clears the
  accumulated body and marks the response privately. capture/1 drops that body
  but preserves status and the existing bounded printable request/retry headers.
  The existing response/error halt steps remain unchanged; no retry, redirect
  or credential source was introduced.
- Existing decode/classify_failure clauses are unchanged. A dropped oversized
  success still fails the existing binary/body validation as malformed_response.
  An oversized error formerly failed error_type's byte bound and used its status
  fallback; nil now follows the same fallback. New cases400,429,500,529 include
  an over-cap valid timeout_error document to distinguish this from parsing its
  early bytes, and preserve throttled/overloaded retry-after metadata. This keeps
  the ready Anthropic Contract rather than importing OpenAI's different rule.
- Pinned Req0.7.5 forwards HTTP-framing-decoded data unchanged to its function-into
  callback. Its compression/decompression steps skip into requests. The original
  provider already halted in its first response step before decompression. Thus
  the wire-body-byte interpretation and raw gzip tests agree with existing
  behavior; the compressed200 remains malformed and compressed429 remains
  throttled. Neither path expands compressed content before classification.
- The measurement test observes actual callback bytes and prior retained body.
  It asserts consumed>cap, consumed<=cap+last_chunk and prior accumulator<=cap.
  Its actual HTTP response withholds the terminal chunk until after the client
  returns. A separate collector-disabled test remains incomplete until that marker
  is released. A further test runs Anthropic.call/2 itself against the same controlled
  transport and requires its raw response before the marker, catching omission of
  the collector from the provider call. These are meaningful transport and wiring
  checks, not only function-plug assertions.
- The listener is explicitly loopback-bound. The server tolerates the expected
  early-close/reset from a rejecting client, and measures received callback bytes
  rather than claiming socket send counts represent consumed data. Cleanup closes
  the listener and terminates any remaining server. These two details were corrected
  during preinspection before the reviewed snapshot.
- Exactly-cap and cap-minus-one valid small Messages documents padded with JSON
  whitespace preserve captured bytes and decoded content, avoiding an unrelated
  interface-output bound. Existing provider test assertions are untouched. The
  new module and helper dependency are both declared in the Piece source closure.
  Actual copied-consumer execution remains a validation requirement.
- README and manifest distinguish a retained application accumulator plus one
  incoming chunk from BEAM heap, TLS and kernel buffers; no physical-process-memory
  proof is claimed. The ready manifest's behavioral Contract string is unchanged.
  Telemetry remains planned; the existing install_configuration and guidance are
  preserved. No dependency, configuration or toolchain pin is changed.
- Reviewer checks: `git diff --check 339c1ed..1bb6ff6` exit0. At the inspected
  final-step planning working tree, `python3 scripts/check-roadmap.py --live`
  exit0 (live bodies and generated views agree), and
  `python3 scripts/test-ci-change-class.py` exit0 (52 tests). The planning
  files/publication copy were still uncommitted; their final hashes and any generated
  ledger must be checked mechanically by the coordinator when published.

## Evidence and integration limits

Read-only source/Contract review and the stated structural checks. No Mix suite,
transport test or collector-disabled mutation was executed by this reviewer. At
review time dependency setup was still building and the work record honestly
reported executable checks pending. Record real outcomes before readiness; do
not present this code approval as evidence that planned tests have run. A later
code/test correction needs review of that actual delta. Record-only transcription
and final scoped metadata need mechanical verification, not a ceremonial new
independent pass. No live Anthropic request, Cure proof or universal memory bound
is claimed.
