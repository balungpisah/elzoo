# ELZ-085 — Specify the batch job-mode interface Piece and the Anthropic Message Batches provider Piece

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/ai-batch (new row: batch interface over text requests), integration/ai-batch-anthropic (new row: Anthropic Message Batches provider)
- Dependencies: ELZ-006, ELZ-011, ELZ-023, ELZ-079

## Outcome

Own the batch job mode of the `integration/ai-model` family for text requests: submit a
bounded set of ELZ-079 text requests under caller-chosen item ids, read the job's state,
fetch per-item results joined by item id, and cancel. Following the owner's model, this task delivers the batch interface Piece and its
first provider Piece, Anthropic Message Batches; OpenAI Batch (Files API plus
`/v1/batches`) is its own provider Piece and task (outlined in the batch summary as
ELZ-088). `req_llm` 1.30.0 has no batch client, so providers are thin own Adapters on Req
(main's decision: thin own Adapters only where `req_llm` does not cover a provider);
per-item request bodies and result decoding reuse the ELZ-079 text translation so a
batched item means exactly what the same synchronous call means. This slice fixes the
job operations over the core's job reference and job state types (fixed in ELZ-079)
that the image and video slices reuse. Owner order
(2026-11-09): "1 text ..., 2 batch job mode, ...". Evidence is stub-only (owner decision
2026-11-09, 23:45 WIB).

This task applies the AI model family design rules recorded in ELZ-079 (owner-agreed, via
main, 2026-11-10): R1 caller first; R2 a provider Piece earns its slot through usage and
cache-accounting translation, failure mapping and conformance stubs, never a re-export of
`req_llm`; R3 a typed, validated provider-options slot in the interface; R4 the shared
family core (`integration/ai-model`) is a dependency; R5 stub evidence proves conformance
to the pinned documented format only, never current live behaviour, and each provider
Piece records that limit.

## Admission record

1. **Responsibility and caller.** Translate batch submission, status, results and
   cancellation to typed outcomes; the interface owns item validation, the join by
   item id, the outcome table and the Effect and intent call path; the provider owns
   wire translation, usage and failure mapping (R2). Callers (R1): C7 scheduled bulk research (many independent
   prompts where a 24-hour window and the provider's batch price are acceptable). Polling
   cadence and durability of the job reference belong to the caller (for example a
   durable job through `integration/jobs`); the Adapter is call-scoped.
2. **Interface and invariant.** Uses the core's `job_ref` and `job_state` (ELZ-079);
   typed provider options (R3) carry provider-specific settings such as Anthropic's
   cache TTL inside batches. Operations: `submit(binding, items, dispatch)` where `items` are 1..N
   `{item_id, text_request}` with unique caller ids (ASCII, bounded), one model per
   submission, total count and bytes bounded below the provider limits; `status(binding,
   job_ref)`; `results(binding, job_ref, page)` returning bounded pages of
   `{item_id, succeeded{ELZ-079 completed result} | errored{class} | cancelled |
   expired}`; `cancel(binding, job_ref)`. Outcomes: `submit` returns
   `submitted{job_ref}`, `refused{...}` (validation before any request, or provider
   rejection) or `unknown{reason}` when the creating request may have reached the
   provider and no answer was observed, and always carries `orphans` (an empty list for
   a single-step submission such as Anthropic's; a multi-step provider reports uploaded
   files whose batch creation was refused or unknown); `status` and `results` are reads
   and return `{:ok, ...}` or a finite error; `cancel` is a write and returns
   `cancelled | refused{reason} | unknown{reason}`: a timeout or connection loss after
   its request was sent is `unknown` (the job may or may not be cancelling), and a
   repeat needs the provider's documented idempotency or a reconciliation by `status`.
   Invariants: every
   result is joined by `item_id`, never by position (OpenAI documents that output order
   is not guaranteed); a result naming an unknown or duplicate `item_id` is a malformed
   page, refused as a whole; an item absent from an ended job's results is reported
   `missing`, never `succeeded`; per-item usage uses the ELZ-079 usage type and the
   provider's batch price is not computed here; a lost `submit` is `unknown` and the
   ELZ-023 intent boundary refuses a second submission of the same dispatch identity
   without a reconciliation decision, because neither provider documents an idempotent
   create (reconciliation by listing recent jobs is allowed only where the provider
   returns a caller tag the Adapter set; otherwise the outcome stays unknown); no
   credential, prompt or output in errors, logs or events. Non-goals: scheduling polls,
   webhooks, embeddings or other endpoints in batch (later), Gemini or Cloudflare batch,
   result retention beyond the provider's window, cost computation.
3. **Reuse check.** Provider facts from main's research (official documentation fetched
   2026-11-09): Anthropic `POST /v1/messages/batches` with up to 100,000 requests or
   256 MB, a 24-hour window, results kept 29 days, result types
   `succeeded/errored/canceled/expired`, joined by `custom_id`
   (Anthropic batch-processing documentation); OpenAI Files API upload with
   `purpose=batch` of a JSONL file whose lines carry `custom_id, method, url, body`, one
   model per file, `/v1/batches` with completion window `"24h"`, output order not
   guaranteed, files deleted after 30 days (OpenAI batch guide).
   `req_llm` only classifies batch URLs for pricing
   (`lib/req_llm/pricing_context.ex:62-63,144-145`). Item bodies: the builder reuses the
   ELZ-079 request translation (preferably by building the `req_llm` request and taking
   its encoded body without sending; see open question 1) so batch and synchronous items
   cannot drift; results reuse the ELZ-079 response decoding. Req (already pinned)
   carries the HTTP calls; no new dependency is expected.
4. **Split test.** The interface and each provider are separate Pieces (owner's model).
   Batch is a job mode with its own lifecycle (submit, poll, fetch,
   cancel), its own failure modes (expiry, partial failure, orphan files) and its own
   evidence, so it is not folded into the synchronous text Piece; it depends on the text
   Piece for item semantics.
5. **Failure and evidence.** Dangerous paths: a lost submission resubmitted blindly (a
   second paid batch); results joined by position; a missing item reported as
   succeeded; an expired job reported as failed items that were billed; an orphan upload
   left unreported; a lost cancel reported as not cancelled; unbounded result downloads; a key or prompt in an error or log.
   Proofs: none required. Type/contract check: captured requests validate against a
   schema hand-derived from the Anthropic batch-processing documentation, with its
   sources and limit recorded. Tests
   (stub-only, documented formats, as job-state sequences, run through the interface's
   conformance kit): submit accepted; submit
   refused for duplicate item ids, mixed models, over-count and over-bytes before any
   request; submit lost after send is `unknown` and a second submission of the same
   identity is refused by the intent boundary; `orphans: []` on every Anthropic submission and a non-empty list validated with a
   test provider; a cancel whose response is lost is `unknown` and reconciled by
   `status`; pending to running to ended; ended
   with mixed `succeeded/errored/cancelled/expired` items; results out of order joined
   correctly; an unknown or duplicated item id in a page refused; a missing item
   reported `missing`; expired job; cancel during running; 401, 404 and 429 mapped;
   result pages bounded; credential and prompts absent from errors, logs and events.
   Upstream: provider batch semantics, windows, retention and pricing are named, not
   proved.
6. **Composition record.** The interface depends on `integration/ai-model` and
   `integration/ai-text` (ELZ-079), `core/effect`, `delivery/effect-intent`,
   `delivery/retry-timeout`; the provider depends on the interface and on
   `integration/ai-text-anthropic` for item translation, and records the R5 limit. Needs:
   the provider keys as injected Needs (never global config, never logged); network
   egress. Telemetry `planned`; Config `supported` (bounds, page size, deadline);
   Control `not_applicable` beyond the provider `cancel` operation, which is a request
   to the provider, not a local drain.

## Scope

- add `pieces/integration/ai-batch/` (interface, conformance kit in `lib/`) and
  `pieces/integration/ai-batch-anthropic/` (provider, stub fixtures and the hand-derived
  schema with provenance), each with README, `piece.json` and tests;
- no new dependency expected (Req is pinned); if one is needed, the class X rule applies;
- add the two catalogue rows and release-plan entries, regenerate `LEDGER.md` and the
  roadmap views.

## Acceptance

- [ ] The listed job-state sequences pass for the Anthropic provider against
      documented-format stubs, and captured requests validate against the hand-derived
      schema.
- [ ] A lost submission is `unknown` and a second submission of the same identity is
      refused without a reconciliation decision.
- [ ] A cancel whose response is lost is `unknown`, never reported as not cancelled;
      `orphans` is present (empty for Anthropic) on every submit outcome.
- [ ] Results are joined by item id; unknown, duplicate and missing items are reported as
      declared.
- [ ] No credential or prompt appears in errors, logs or Adapter events, with a test.
- [ ] The two Pieces' tests pass in the exported consumer layout.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] `mix check --affected <base>` and the Pieces' tests pass; full checks if a
      dependency or configuration changed.

## Evidence and limits

Finite stub tests over listed job-state sequences; upstream contracts of the providers'
batch APIs; no proof and no live call. No claim about turnaround time, the batch
discount, retention or live provider behavior.

## Out of scope

Poll scheduling and durable job storage (caller's), webhooks, embeddings and other
endpoints in batch, Gemini, Cloudflare, Groq and Mistral batch, cost computation.

## Reference

Owner slice order (2026-11-09); main's model-type research (batch section, sources
there); decision record `integration/ai-model`; ELZ-079.

## Open questions (none blocks a builder)

1. Item body construction: reuse `req_llm`'s request preparation and take the encoded
   body without sending (recommended; the builder confirms there is a supported way) or
   encode from the ELZ-079 request types directly with a conformance test that the bodies
   equal the synchronous path's.
2. Whether embeddings in OpenAI batch (`/v1/embeddings` lines) join this slice or wait;
   recommended: wait for a caller.
