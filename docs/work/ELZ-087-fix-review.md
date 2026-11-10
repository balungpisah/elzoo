# ELZ-087 narrow independent fix review

Reviewer: independent Codex reviewer, role reviewer-087-fixes.
Reviewed SHA: `fc1d68d93b5dd30c8aac31d43ff4292332ddead0`.
Reviewed range: `d6a254d8721e1569d646ab0b1dbd394bc9ff9c16..fc1d68d93b5dd30c8aac31d43ff4292332ddead0`.
Live Contract: issue #157. PR #167. Prior narrow review: ELZ-087-rereview.md.

## Verdict

Approve the implementation and evidence additions in this range. No blocking code
findings remain from the prior narrow review. Final PR-description synchronization,
exact-head hosted acceptance and merge cleanup remain coordinator responsibilities.

## Findings and grounding

- Oversize precedence is repaired. `capture/1` carries the collector's oversize flag
  into the exchange, and the first `decode/2` clause returns malformed_response
  before the success/error-status branches. O13 checks oversized400,429,503 bodies,
  one captured request per call, the unknown/malformed result and absence of the
  body marker and key in inspected results/state, logs and telemetry. This directly
  covers the prior high finding without changing the text-interface outcome table.
- Compressed representation is explicit and agrees with pinned local Req0.7.5
  source. Req.Finch.finch_stream_into_fun/5 forwards data unchanged;
  Req.Steps.compressed/1 skips accept-encoding injection when into is non-nil,
  and decompress_body/1 returns that response unchanged. The Elzoo capture step
  also halts before later response steps. The README and manifest now name4MiB
  wire bytes after HTTP framing. O14 exercises gzip bytes under that cap whose
  expanded form exceeds it: capture retains encoded bytes, while the provider
  returns malformed_response rather than attempting decompression. This clarifies
  the unmerged provider's existing transport boundary; no ready Contract is changed.
- O15 deletes max_output_tokens and checks zero credential reads. Its refused/2
  helper creates a stub that fails on any request and asserts the captured request
  list is empty. Thus the new case establishes the stated pre-Need/pre-send refusal.
- O16 uses actual Req/Finch against a disposable chunked HTTP server. The server
  transmits4MiB+1 and withholds its terminator until after the client returns; the
  asserted successful response with oversize:true cannot result from ordinary
  complete-body buffering. Together with O13, which exercises provider call wiring,
  this separates collector behavior from full-call outcome mapping. The work record
  reports a collector-disabled mutation failing by timeout and appropriately limits
  its memory claim. This review inspected the code and recorded result; it did not
  execute or independently repeat that mutation. The socket and server task have
  bounded cleanup in the test's after block.
- The standard generated-by attribution is retained under the coordinator decision
  referenced by the work record. Repository coordination rule5 explicitly exempts
  standard tool attribution lines and commit trailers from private information.
  The prior review's conflicting recommendation does not require its removal.
- Scope remains the new provider Piece, its evidence/task records, and its own
  generated metadata. `git diff --check d6a254d8..fc1d68d` passed. The narrow diff
  introduces no dependency/configuration/toolchain edit or unrelated runtime change.

## Integration note

The PR description read during this review still describes the earlier head and
contains an obsolete ELZ-091 installation-field-pending statement. The writer must
update it to the already-present install_configuration declaration and the new
checked head/run before readiness. This is a transcription correction and needs
no further independent code pass if the implementation remains unchanged.

## Limits

Read-only source, pinned-upstream-source, Contract and evidence review. No Mix gate,
new runtime test, provider call or universal memory/scheduling proof was performed.
The original final review's unchanged implementation is outside this narrow pass.
