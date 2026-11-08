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
2. **Interface and invariant.** `select(request, context)` accepts ordered
   candidate data in `request` and host-owned window, reservations, current
   access/provenance snapshot, evaluation time and policy in trusted `context`;
   the exact authority split and bounds below are part of this Contract.
   Outputs: ordered `selected`, per-occurrence
   `dropped{item_id, reason ∈ {access_denied, stale_access_check, over_window,
   superseded, policy}}` with detail, and `total_estimate` tagged with
   `estimator_id`. State owner: none; pure decision owned by the calling Run.
   Invariants: `sum(selected.estimate) + sum(reservations) <= window.size`;
   every selected item has an allowed retrieval record for the trusted principal
   and an allowed current check, bound to tenant/item/version/source/hash, with
   `checked_at <= snapshot_at <= now` and `now - checked_at <= policy.max_age`;
   a derived item is selected only when every transitive source is permitted,
   and is tagged derived (model output, an untrusted proposal, never retained
   fact); superseded versions drop as `superseded`; equal inputs give equal
   output; unknown models/providers have no default window and fail explicitly;
   selected count and actual bytes obey trusted policy caps, distinct from
   fixed ingress ceilings; dedupe uses `content_hash`, falling back to
   `(item_id, version)`. Non-goals: tokenization, retrieval, summarization,
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

## Accepted interface and evidence conditions

Authorized by root coordinator `RUN:RUN_53A86670020C` on 2026-11-08
approximately 04:20 WIB, relayed through the pieces coordinator; D1-D5 accepted
in strict form after review of `e737807d5a0c8c3b365fb91a2824ccab12f1c861`.
This amendment changes this not-yet-ready task only, not any ready Contract.

### Authority and data

The only supported surface is `Elzoo.ContextSelection.select(request, context)`.
`request` has only `candidates`; all authority/configuration is host-controlled
in `context`: principal, tenant, evaluation `now`, `snapshot_at`, chosen window,
closed window registry, reservations, policy and provenance nodes/current checks.
Unknown request keys, including attempts to override any of those fields or
policy members, are rejected. Candidate priority and content are data; the host
chooses whether priority/recency ranking applies. No model-supplied authority.

Candidate fields are `item_id`, positive integer `version`, `source`, materialized
`content`, nonnegative `estimate`, integer `priority`, retrieval-time
`access{principal, checked_at, result}`, ordered `derived_from` references and
`content_hash` (nil or 32 bytes); `updated_at` is required only for recency ranking.
References are exact `(item_id, version)` pairs. The window declares
`provider_id`, `model_id`, `size`, `unit` (`tokens` or `bytes`), `estimator_id` and
`estimator_version`, and must exactly match the host's closed registry; unknown
provider/model or mismatched window fails explicitly. Policy declares `max_age`,
`allow_derived`, priority/recency ordering, `max_selected_count` and
`max_selected_bytes`; none may be relaxed through `request`.

Every candidate must match a trusted provenance node by `(item_id, version)`,
source, hash and the exact ordered `derived_from` list. A node supplies `tenant`,
`item_id`, `version`, `source`, `content_hash`, `derived_from` and `check`; its
check is the current access result for that item, including when the node is
not a candidate. Thus no candidate can hide derivation by omitting its sources.
Checks contain tenant, principal, item_id, version, source, content_hash,
checked_at and allowed/denied result, bound to that node and the trusted context.
`check: nil` means unchecked. A missing node differs from a node with no check.
Ancestor bytes need not be supplied or selected. Host Needs include complete,
truthful provenance and immutable identity/version binding when no hash exists.

Retrieval-time denied vetoes selection (`access_denied/retrieval_denied`), and
a retrieval principal unequal to the trusted principal vetoes it
(`access_denied/principal_mismatch`), even when current access is allowed.
Otherwise only the current check can permit it: missing own check gives
`access_denied/missing_check`, denied gives `access_denied/denied`, and tenant
or other binding mismatch gives `access_denied/binding_mismatch`. Retrieval
access is evidence only, never a fallback. Every selected item has both an
allowed retrieval record for the principal and an allowed, bound current check
with `checked_at <= snapshot_at <= now` and `now - checked_at <= max_age`.
Output retains retrieval evidence separately from the current `access` field.

The host supplies a coherent snapshot and time from one host clock reading,
with `now >= snapshot_at`, and rechecks relevant changes before actual injection.
Revocations represented in that snapshot exclude items and their derivatives;
revocations after the snapshot are invisible to this pure Piece. A freshness
interval is not a guarantee of live permission. ELZ-024 read-policy translation
is an explicit consumer fixture over its exact-write reducer, not general ACLs.

The Elixir boundary verifies every non-nil `content_hash` equals SHA-256(content)
using the named OTP `:crypto` Need, rejects bytes-unit `estimate < byte_size(content)`,
and passes byte_size and identifiers, never content, into Cure. Nil hashes keep
the `(item_id, version)` dedupe fallback. Token estimates remain external estimates;
no tokenizer/provider accuracy or silent truncation is claimed. There is no
future-item rejection; `updated_at` is a ranking operand only.

### Bounds and deterministic policy

Fixed ingress ceilings: 256 candidate occurrences, 8 MiB total candidate content
before dedupe/filtering, 1 MiB per candidate, 256 distinct trusted provenance nodes,
16 references per node, 16 nodes per provenance path, 32 named reservations and
32 windows. Identities/names are at most 1024 UTF-8 bytes; versions are 1..2^31-1;
nonnegative scalar amounts/times are 0..2^53-1; priority is -(2^31)..2^31-1.
Conflicting duplicates fail the whole call (an availability failure, no output).

Selected caps are separate trusted per-call settings: `max_selected_count`
0..256 and `max_selected_bytes` 0..8 MiB, counting actual selected content bytes,
not token estimates. After access, freshness, supersession and provenance checks,
dedupe eligible candidates (hash first, otherwise exact reference), then greedily
check window fit, count cap, byte cap, in that order. Failures drop with
`over_window/insufficient_window`, `policy/count_limit`, `policy/byte_limit`;
continue to later candidates. No fallback to an older version or a later
eligible duplicate if the chosen newer/first-ranked item does not fit. Highest
numeric version is relative to the union of supplied candidates and nodes.
Rank by enabled priority descending, enabled recency descending, then input
index ascending; selected follows rank, dropped follows input occurrence order.

Compute each provenance node verdict once in dependency order and memoise it;
never enumerate all paths. Additionally enforce a hard total expansion budget
of 4096, counting one per distinct supplied node plus one per declared outgoing
reference occurrence (even to a shared/missing node); count the whole graph
before evaluation and fail the whole call with `bound_exceeded` above the budget.
Traversal uses structural fuel, not an integer termination assertion. Each node's
cached verdict/depth is reused; shared paths are not charged or evaluated again.
This is both memoisation AND a hard budget, not a choice between them.

For candidate own checks, retrieval vetoes precede current access, then freshness,
then supersession, then derivation policy/provenance. Missing node is
`policy/missing_node`; a referenced node with nil check is
`access_denied/source_unchecked`; denied/stale ancestors are
`access_denied/source_denied` / `stale_access_check/source_stale`.
Cycles/depth overflow fail closed as policy drops. At each node, own failure
precedes ancestor failures; among references choose the first failed reference
in declared order, regardless of memoisation or processing order. Tenant mismatch
is `access_denied/binding_mismatch`, including at an ancestor. Superseded ancestors
are rejected relative to supplied nodes/candidates. All source nodes and checks
must be permitted, even when the sources are not themselves selected.

### Proof and executable gates

The window and access laws quantify over well-typed Cure inputs and establish
safety of successful results only; the Elixir validation/encoding precondition
is explicit. Guard predicates and law predicates are separately written; final
guards recompute window, current/transitive access and selected count/bytes from
the returned selection. No assumed safety invariant or disconnected model.
Use `local fn` helpers to express intent, without claiming BEAM-level privacy;
the facade and caller example must call only the Cure selection entry point.
Native numeric arithmetic/comparison, String/binary byte equality and list
semantics are named pinned Cure/BEAM upstream contracts, with finite comparison
agreement tests. Laws do not prove progress, ranking, selection correctness,
candidate membership, authenticity or accuracy of external estimates.

Positive non-refusal scenarios are mandatory: selected item, revoked-excluded,
stale-excluded, exact window fit, exact-age boundary, derived-with-allowed-source
and derived-with-denied-source. Mutation shapes E2 (always refuse), E3 (remove
filter) and E4 (weaken both predicate and guard freshness) must fail a scenario;
do not require or claim that every such mutation must fail a proof. Add recursive
provenance feasibility with structural fuel before production coding. Production
Cure totality remains a gate: if it cannot be checked, move closure computation
to Elixir with a flat ancestor check in Cure and state closure correctness is
test-grounded; do not claim an unproved recursive-provenance law.

## Scope

- define the pure selection function and result schema;
- select the window and access laws;
- test the listed dangerous paths.

## Acceptance

- [ ] A revoked item represented in the current snapshot is never selected
      (executable test); retrieval allowed/current denied, retrieval denied/current
      allowed, retrieval principal mismatch and missing current check are tested.
- [ ] Request override attempts for every moved authority/configuration field
      are rejected; tenant binding, hash verification and bytes undercount are tested.
- [ ] Selected window and access laws run through mix check, over well-typed
      Cure inputs with explicit validation precondition and successful-result
      scope; separate guard/law predicates, native assumptions and facade-only
      supported entry are checked as specified above.
- [ ] All seven named positive non-refusal scenarios pass; E2/E3/E4 mutations
      each fail a scenario, independently of whether their proofs pass.
- [ ] Derived items carry provenance and are rejected when a source is denied;
      transitive missing-node, unchecked-source, tenant, cycle, depth and ordered
      failure scenarios pass, with recursive feasibility/totality grounding stated.
- [ ] Distinct ingress and selected caps, plus memoisation AND the 4096 expansion
      budget, are exercised; a 16-layer by 16-node DAG at the budget and a
      one-reference-over-budget variant complete within a named time bound.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Selected laws and listed scenarios; no claim about retrieval quality or
memory.

## Out of scope

Retrieval, embeddings, summarization, persistent agent memory.

## Reference

Shapes observed in sigil 0.1.4 context budgeting and bankai 0.4.0 memory
priming; see docs/research/ecosystem-round-2.md. No code is copied.
