# ELZ-093 independent early Contract review

Reviewer: independent Codex reviewer, role reviewer-093-early.
Reviewed base: `339c1edb6925afd324280f95c2dd7591ae1f96ee`.
Reviewed input: uncommitted docs/work/ELZ-093.md preflight and live issue #171;
existing Anthropic provider, README, manifest and tests; pinned Req0.7.5 source.
No implementation existed at review time.

## Verdict

Proceed after the two factual preflight corrections below. No Contract amendment
or new Piece ID is needed for the proposed bounded-reception repair if the coder
preserves the existing status outcomes and the evidence conditions below.

## Required preflight corrections

1. Telemetry is currently **planned**, not inherited. The ready manifest explicitly
   declares no own event and describes only possible upstream observations. Keep
   that status and its current limits; this task does not establish inherited
   telemetry or authorize a new applicability claim.
2. At the reviewed base, the Anthropic manifest already declares exactly
   `config :req_llm, load_dotenv: false` in install_configuration and its README
   already describes the exporter field. Preserve and verify this existing
   installation behavior rather than claiming a new adoption in this task.

## Contract and implementation constraints

- Existing oversized2xx decode is malformed_response. Existing non-2xx decode
  ignores an over-cap body's error_type and classifies from status, retaining
  retry-after metadata for throttled/overloaded cases. In particular, do not copy
  the OpenAI oversize-first decode clause: that would change the ready Anthropic
  outcome behavior. Discarding an oversize body while retaining status/headers
  can preserve the same outcomes without such a clause.
- The existing capture is prepended before all Req/req_llm response steps and
  halts the response. It therefore already precedes decompression. Pinned Req's
  function-into Finch path forwards received data chunks unchanged; compressed/1
  skips automatic accept-encoding insertion when into is non-nil, and
  decompress_body/1 skips such responses. Name the bound as wire body bytes after
  HTTP framing and check a content-encoded reply against the old raw-capture
  behavior. Neither code path should expand compressed input into an unbounded
  decoded buffer. Non-2xx compressed bodies still use the existing status fallback.
- Retained application accumulator must never exceed4MiB; the incoming callback
  chunk may momentarily coexist with it. Stop before concatenating an overflowing
  chunk and drop the retained body. This is an accumulator/receive-contract claim,
  not an exact BEAM heap, garbage-collection, TLS, kernel-buffer or total-process
  memory proof. Preserve this distinction in README and evidence wording.
- Early halt must return a captured response through the normal provider call
  rather than turning oversize into a transport failure. Keep the existing
  no-retry/no-redirect steps and the credential/prompt/output redaction boundary.

## Evidence requirements before final review

- Add actual transport evidence with a response whose terminating body marker
  is withheld. Assert the client returns on oversize before completion; count
  bytes and maximum chunk size delivered to the collector, not merely bytes
  sent by a server into socket buffers. The consumed count at rejection should
  be bounded by cap plus the actual last receive chunk. Include a negative
  control that disables the collector and fails this early-return assertion.
- Exercise the collector through the actual provider call at least once, or
  otherwise pair the transport test with a meaningful provider-wiring negative
  control; a standalone function test cannot alone prove it was installed.
- Exactly-cap and cap-minus-one valid documented Messages replies must retain
  their decoded outcome. Whitespace padding around a valid small JSON body can
  exercise raw-size boundaries without conflating them with an interface output
  size limit. Check representative oversized error statuses, including a body
  carrying timeout_error that the old over-cap parser ignores, and retry-after.
- Existing provider assertions stay unchanged. Keep loopback transport helpers
  in this Piece's declared test closure, and demonstrate copied-consumer layout
  compatibility. No live Anthropic request or spend is authorized.
- Run the task's affected gate, Piece tests and full exact-head hosted acceptance;
  no dependency/configuration/toolchain change is proposed, so the separate class-X
  local full run is not introduced by this plan. Final independent review remains
  required on the actual implementation and scoped evidence claims.

## Grounding and limits

Read-only preflight, existing-source and pinned-upstream-source analysis. No
Mix command, provider request, repository mutation or new proof was performed.
This is permission to implement within the published Contract, not final code
acceptance or a claim that planned tests already pass.
