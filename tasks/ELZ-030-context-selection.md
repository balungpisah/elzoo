# ELZ-030 — Specify bounded, permission-checked context selection

- Phase: demand-led workflow policy
- Catalogue IDs: workflow/context-selection
- Dependencies: ELZ-003, ELZ-024

## Outcome

Decide which permitted, versioned items enter one model call under a declared
size window, and record what was dropped and why. Retrieval, tokenization and
summarization stay outside; agent memory remains product-level behaviour per
docs/capability-model.md. This Piece is the pure selection step C6 and C7
need.

## Admission record

1. **Responsibility and caller.** Select an ordered, bounded, permitted set
   of candidates with per-item drop reasons. Callers: C6 (bounded child runs
   with artifacts as context) and C7 (scheduled research with scoped
   retrieval). A human review queue assembling a bounded brief from permitted
   documents challenges generality without a model.
2. **Interface and invariant.** Inputs: `window{size, unit, estimator_id}`,
   `reservations{name → size}`, ordered candidates `{item_id, version,
   source, access{principal, checked_at, result}, estimate, priority,
   derived_from}`, policy (recency, priority, derived-item allowance,
   access freshness). Outputs: `selected` (ordered), `dropped{item_id,
   reason ∈ {access_denied, stale_access_check, over_window, superseded,
   policy}}`, `total_estimate` tagged with `estimator_id`. State owner: none;
   pure decision owned by the calling Run. Invariants: `sum(selected.estimate)
   + sum(reservations) <= window.size`; every selected item has
   `access.result = allowed` with `checked_at` within the freshness policy; a
   derived item is selected only when every source it references is itself
   permitted, and it is tagged derived (model output, an untrusted proposal,
   never retained fact); a superseded version is dropped as `superseded`;
   selection is deterministic for equal inputs; an unknown model or provider
   has no default window and selection fails explicitly; injected items are
   bounded in count and bytes by policy, never "all records"; dedupe is by
   content identity. Non-goals: tokenization, retrieval, summarization,
   truth or memory claims.
3. **Reuse check.** Provider count APIs and tokenizer libraries supply
   estimates (req_llm is the listed integration candidate); per-category
   reservations and compaction strategies seen in sigil and bankai are
   policy inputs, not dependencies; summarization is an integration/ai-model
   Effect producing a derived candidate. The remaining policy (access
   freshness, drop reasons, derived-item provenance) is Elzoo's.
4. **Split test.** Window arithmetic and the access/provenance filter share
   one invariant and stay behind one interface. Estimator, retrieval and
   summarization are separate Adapters.
5. **Failure and evidence.** Dangerous paths: an item whose access was
   revoked after retrieval still selected (C7); a summary replacing items
   whose sources were denied; an estimate undercount surfacing as silent
   truncation instead of a provider result; a default window for an unknown
   model. Proofs: window law and access law over the pure selection in Cure.
   Tests: revocation between retrieval and selection, superseded versions,
   derived-item provenance, deterministic ordering. Upstream: estimator
   accuracy and provider limits are named, never proven.
6. **Composition record.** Depends on core/envelope item references,
   domain/authorization (ELZ-024) for access results, integration/ai-model
   for estimates and derived items, domain/metering for reconciling observed
   usage. Context may carry secrets by accident; integration/secrets rules
   apply. No delivery guarantee implied.

## Scope

- define the pure selection function and result schema;
- select the window and access laws;
- test the listed dangerous paths.

## Acceptance

- [ ] A revoked item is never selected (executable test).
- [ ] Selected window and access laws run through mix check.
- [ ] Derived items carry provenance and are rejected when a source is denied.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Selected laws and listed scenarios; no claim about retrieval quality or
memory.

## Out of scope

Retrieval, embeddings, summarization, persistent agent memory.

## Reference

Shapes observed in sigil 0.1.4 context budgeting and bankai 0.4.0 memory
priming; see docs/research/ecosystem-round-2.md. No code is copied.
