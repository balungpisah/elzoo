# ELZ-085 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `95caebb480ec0b24737da3db3be0fed770170777`

Verdict: **proceed after fixes**

## Inputs reviewed

- Live issue [#158](https://github.com/balungpisah/elzoo/issues/158), read with `gh issue view 158 -R balungpisah/elzoo --json body --jq .body` on 2026-11-09.
- `git show 95caebb480ec0b24737da3db3be0fed770170777:docs/work/ELZ-085.md` and `git diff origin/main...95caebb480ec0b24737da3db3be0fed770170777` (one added proposal file; `git diff --check` clean).
- The named SHA's `AGENTS.md`, `docs/operational-contracts.md`, `docs/consuming.md`, ELZ-079 Pieces, and `delivery/effect-intent` Contract/source.
- Local, pinned dependency source only: req_llm 1.30.0 (Hex checksum recorded in `mix.lock`) and Req 0.7.5. No Mix command or provider call was made.
- Official documentation used to cross-check the stated batch facts: [Create a Message Batch](https://platform.claude.com/docs/en/api/messages/batches/create), [beta Create a Message Batch](https://platform.claude.com/docs/en/api/beta/messages/batches/create), and [Versions](https://platform.claude.com/docs/en/api/versioning), accessed 2026-11-09.

## Findings

1. **High — raw submissions are in the EffectIntent owner state under the proposed manifest design.**
   - Location: `docs/work/ELZ-085.md:149-159`, against the redaction invariant at lines 132-137 and its proposed test at lines 266-276.
   - `Elzoo.EffectIntent` retains `adapter_context` in its GenServer state and passes it to every adapter request (`pieces/delivery/effect-intent/lib/elzoo/effect_intent.ex`, `init/1` and `request/2`). Passing `Elzoo.AiBatch.context(config, submission)` therefore retains the raw prompt-bearing bytes in owner state, contrary to the proposed redaction claim. The bytes are not durable Store arguments, but that is a narrower claim.
   - Concrete change: replace raw `submission` in `adapter_context` with a host-owned, redacted lookup capability keyed by the intent key plus manifest digest. It must yield the exact immutable canonical bytes only to the adapter task; the owner state/Inspect/log surface must contain neither bytes nor a closure/captured value that exposes them. Alternatively narrow the Contract and tests explicitly to durable intent state, but that loses the stated owner-state redaction guarantee.

2. **High — call-scoped cancel leaves the required no-repeat/reconciliation rule unenforced.**
   - Location: `docs/work/ELZ-085.md:125-130, 327-332`.
   - Anthropic does not document cancel idempotency, and `status` can show only an observed state, not a durable command receipt. A documented caller rule permits a repeat after `unknown` without the exact guard that the issue's dangerous path requires; “not a paid effect” does not make a second external write harmless or prove it did not happen.
   - Concrete change: use a distinct `delivery/effect-intent` Binding with operation `cancel`, identity including the provider job reference and caller cancel identity. It must refuse a second dispatch after an unknown unless a named authenticated reconciliation ground is recorded. State explicitly that `:ending`/`{:ended, _}` is an observation used to decide the business state, not proof that a particular cancel attempt was the cause; if no ground exists, remain unknown/refused rather than resend.

3. **High — a new public completion function is an additive public Contract on ready `integration/ai-text`, not a no-behaviour-change extraction.**
   - Location: `docs/work/ELZ-085.md:246-247, 319-326`.
   - Existing `Elzoo.AiText.Adapter.complete/3` is private. Making it public gives copied consumers a newly supported input/output/error surface. Under `AGENTS.md` “Evolving a ready Contract,” that is a ready-Piece Contract expansion; it cannot be described as no change merely because existing synchronous outcomes are preserved.
   - Concrete change: choose option (b) for this task: own the batch completion check in `integration/ai-batch`, and test equality with the synchronous result across the named conformance corpus plus invalid-tool, structured-output, usage-absent, provenance and malformed-response cases. If maintainers instead need shared public completion functionality, admit a new Piece ID/dependency and migration/ledger work first; main-coordinator approval alone does not waive the ready-Contract rule.

4. **Medium — body equality does not establish semantic equality until batch-global headers are constrained and tested.**
   - Location: `docs/work/ELZ-085.md:163-181, 214-230`.
   - req_llm documents the Advanced Req Plugin path (`prepare_request/4` then `Req.request/1`) and its provider behavior documents `encode_body/1`; manually invoking the public callback is a supported pinned-library use. But `request.options[:json]` is an observed Req/req_llm representation, not a documented enduring body-result API. More importantly, `anthropic-version` and `anthropic-beta` are request headers, not `params`; Anthropic's batch API applies them to the batch request. A sorted union may be valid for selected beta features, but it does not prove every item has precisely the synchronous header set or that arbitrary future/per-item betas compose.
   - Concrete change: retain the approach only as an upstream contract pinned to req_llm 1.30.0, with a regression probe that asserts the encoded map and every relevant header. Declare an explicit allowed set of batch-global header features, derive the outer header deterministically, and refuse a submission when an item's required header set is not safely batch-global/compatible. Validate the outer `anthropic-version` and exact beta union in the documented-format stub. Keep the body-equivalence claim scoped to the finite corpus, after removal of `stream: false`; do not say it guarantees all synchronous semantics.

5. **Medium — results paging needs an explicit scan budget and terminal outcome.**
   - Location: `docs/work/ELZ-085.md:111-124, 187-190, 274-289`.
   - Anthropic results have no paging parameter. With a line-count cursor, every later page re-reads and discards all preceding lines. A bound only on returned page bytes does not bound that read; a bound on all bytes scanned can make a deep cursor unavailable. Neither behavior is presently part of the return Contract.
   - Concrete change: define the cursor (for example, validated line ordinal), bound **all bytes and lines scanned including skipped lines**, and add a finite `:result_scan_limit`/`:too_large` error when the cursor cannot be reached within that bound. Document that this provider does not guarantee retrieval of every 100,000-item result under a smaller configured scan cap. Test a deep cursor that crosses the scan cap, in addition to oversized-line and normal page tests.

6. **Medium — provider-limit and admission/result vocabulary need exact closure.**
   - Location: `docs/work/ELZ-085.md:83-89, 90-116, 191-206, 257-297`.
   - The proposal says bounds are “within” provider limits but leaves the actual configuration inequalities and outer-wire measurement unspecified. The documented batch limit is 100,000 requests and 256 MB for the complete create request, not merely the canonical submission. Also, the public submit table and pre-owner admission table use different outer shapes, while `status` refers to internal ai-text failure reasons rather than one enumerated interface error set.
   - Concrete change: make Config validation enforce `1 <= max_items <= 100_000`, a concrete byte unit and `max_create_wire_bytes <= 256 MiB`; measure the exact encoded outer create body (requests wrapper, ids and params) before send, with overflow-safe arithmetic. State whether equality with the documented maximum is allowed. Name separate `admission/2` versus sink-delivered submit result types, and enumerate the mapped finite status/results/cancel error reasons rather than referring to the ai-text table. Add boundary-minus-one, boundary, boundary-plus-one and wrapper-overhead tests.

7. **Low — evidence and operational declarations are otherwise appropriately scoped, but source paths must preserve the stated exported layout.**
   - Location: `docs/work/ELZ-085.md:232-310`.
   - R5 is correctly limited to documented-format stubs, the hand-derived schema is identified as non-official, `orphans` is always present and empty for Anthropic, joining/missing/duplicate behavior aligns with #158, and `Telemetry planned`, construction-time `Config supported`, and non-lifecycle `Control not_applicable` fit `docs/operational-contracts.md`. The proposed family split and own Req adapter also fit the reuse boundary.
   - Concrete change: ensure each new `piece.json` lists every README, library, fixture and test named here; have metadata ground `Config supported` in its concrete tests; cite the exact Anthropic sections and fetch date in the schema provenance; test outer version/beta headers, absent `stream`/`speed`/`fallbacks`, `max_tokens > 0`, and no raw context in owner-state inspection. Do not change `integration/ai-text` or exporter paths for the rejected Q2(a) route.

## Answers to Q1–Q4

1. **Q1 — proceed conditionally, not as an unconditional equivalence guarantee.** `prepare_request/4` is the documented non-streaming Advanced Req Plugin path, and `encode_body/1` is a documented `ReqLLM.Provider` callback. In req_llm 1.30.0's Anthropic provider, direct invocation produces `request.options[:json]` without sending, so the P1 approach is a reasonable pinned upstream dependency. It proves neither that `options[:json]` is a stable public result field nor that body equality covers headers. Batch `params` can equal the synchronous body minus `stream: false`; outer `anthropic-version` and beta headers must be carried on batch creation and subjected to the header-compatibility/refusal rule in Finding 4. The test is finite conformance evidence, not a general guarantee that every synchronous call has the same batch meaning.

2. **Q2 — choose (b).** Q2(a) adds a public callable surface to ready `integration/ai-text`, hence changes its public Contract under the ready-ID rule. Use a batch-owned copy plus an equality corpus now; a future shared public helper needs a separately admitted new ID or an explicit Contract evolution approved and integrated on main.

3. **Q3 — choose the second Binding.** It is the honest way to make “repeat needs documented idempotency or reconciliation” a boundary rule rather than caller etiquette. A call-scoped cancel is acceptable only if the Contract expressly offers no duplicate-safety claim; that would be weaker than the issue's intended unknown/reconciliation discipline.

4. **Q4 — sound only after the host-context redesign.** A canonical manifest containing length and SHA-256, verified before credential lookup and send, detects ordinary mutation between admission and send; EffectIntent's identity/history prevents automatic replay of a possibly sent submit. It does not by itself solve raw data retained in owner context, host restart/recovery of the bytes, SHA-256 collision assumptions, or an implementation that re-encodes instead of sending the checked exact bytes. Bind the lookup to intent key, binding digest and manifest digest; make the supplied bytes immutable and exact; preserve the no-send classification accurately; document the restart limit; and treat SHA-256 collision resistance as an upstream cryptographic assumption, not a proof.

## Alignment summary

- **Issue outcome and join requirements:** the proposed `orphans` field, Anthropic empty-orphan rule, item-id join, whole-page refusal for unknown/duplicate ids, and ended-only missing calculation align with #158, subject to the admission/result-shape clarification in Finding 6.
- **ELZ-079 family semantics:** reuse of the failure matrix, `429`/`529` as dispatched retryable failures without default redispatch, and absent usage as `:unknown` is aligned. Do not add a no-send tag for a locally observed context mismatch unless the Binding's attestation is deliberately changed and grounded.
- **Scope:** new interface/provider directories, Req transport, documented stubs and hand-derived schema are in scope. A public ai-text helper is not in scope under the current ready ID; no dependency, configuration, exporter or lockfile change is otherwise justified.

## Counts

- High: 3
- Medium: 3
- Low: 1
- Verdict: proceed after fixes
