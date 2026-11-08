# Context selection

`workflow/context-selection` is a pure Operator for building a bounded model call
or human-review brief from permitted versioned items. It returns ordered selections
and a reason for every dropped occurrence. It does not retrieve, tokenize,
summarize, persist, or establish truth. Derived content remains an untrusted
proposal, never a retained fact.

The supported surface is `Elzoo.ContextSelection.select(request, context)`.
See [the bounded brief caller](examples/brief.exs). No process or root Application
is needed. The host owns **all** of `context`; never populate its authority or
configuration from model/tool request fields.

## Inputs and Needs

All maps use exactly the listed atom keys, except optional `updated_at`.
IDs/names are nonempty valid UTF-8 binaries. Content is an arbitrary binary.
Times share one host clock domain; this Operator does not read a clock.

```elixir
request = %{candidates: [candidate]}
context = %{
  principal: id, tenant: id, now: time, snapshot_at: time,
  window: window, windows: [window], reservations: [{name, amount}],
  policy: %{max_age: amount, allow_derived: boolean,
            priority: :input | :descending, recency: :input | :newest,
            max_selected_count: count, max_selected_bytes: bytes},
  provenance: [node]
}
window = %{provider_id: id, model_id: id, size: amount,
           unit: :tokens | :bytes, estimator_id: id, estimator_version: version}
candidate = %{
  item_id: id, version: version, source: id, content: binary,
  estimate: amount, priority: integer, content_hash: nil | <<_::256>>,
  derived_from: [ref],
  access: %{principal: id, checked_at: time, result: :allowed | :denied}
  # updated_at: time is required only for recency :newest
}
ref = %{item_id: id, version: version}
node = %{item_id: id, version: version, tenant: id, source: id,
         content_hash: nil | <<_::256>>, derived_from: [ref], check: nil | check}
check = %{item_id: id, version: version, tenant: id, source: id,
          content_hash: nil | <<_::256>>, principal: id, checked_at: time,
          result: :allowed | :denied}
```

The host supplies complete truthful provenance and a coherent access snapshot:
checks and `now` come from one host reading, with `snapshot_at <= now`. Every
candidate must agree with its node's source/hash/ordered references. Ancestors
need nodes/checks but need not supply content or be selected. Nil hashes require
host-guaranteed immutable identity/version/content binding. Supersession knowledge
is relative to the union of supplied candidates and nodes, not an external store.

Current access is never taken from request data. Retrieval denied or a retrieval
principal different from `context.principal` vetoes selection even if current
access allows. Otherwise current checks must be bound to tenant, principal,
item/version/source/hash, allowed, `checked_at <= snapshot_at <= now`, and no older
than `max_age`. The host must reflect revocations known at snapshot creation and
recheck relevant changes before injection. Revocations after that snapshot are
invisible; freshness tolerance does not establish live permission.

The chosen window must exactly match its provider/model entry in the closed
registry. No unknown-model default exists. Reservations and estimates use that
window's unit/estimator. OTP `:crypto.hash(:sha256, content)` verifies each supplied
candidate hash. A bytes estimate below actual content bytes is invalid. Token
accuracy and provider limits are external Needs; content is never truncated.
Cure receives identifiers, metadata and byte sizes, **never content**.

Dependencies `core/envelope` and `domain/authorization` support the consumer
fixtures. Envelope transport/schema versions are distinct from item versions.
The ELZ-024 fixture translates its **exact-write read marker** to current access;
it does not claim ELZ-024 supplies general read ACLs. No external effect occurs.

## Bounds and policy

| Operand | Bound |
| --- | --- |
| Candidate occurrences | 256 before filtering/dedupe |
| Candidate content | 1 MiB each; 8 MiB total before filtering/dedupe |
| Distinct candidate/node identities | 256 combined; no separate ancestor allowance |
| Trusted nodes | 256; unique item/version keys |
| References per node/candidate | 16, distinct, in declared order |
| Successful provenance path | 16 nodes including the candidate |
| Graph expansion | 4096 = supplied node entries + outgoing reference occurrences |
| Windows / reservations | 32 each; unique provider/model pairs / names |
| IDs/names | 1..1024 UTF-8 bytes |
| Item/estimator version | 1..2^31-1 |
| Scalar amount/time/age | 0..2^53-1 integer |
| Priority | -2^31..2^31-1 integer |
| Selected count / selected bytes | trusted per-call 0..256 / 0..8 MiB |

Missing candidate nodes normally drop that occurrence. Their identities still
consume the combined 256-identity capacity. A node disagreeing with candidate
metadata fails the whole call. Conflicting candidate duplicates also fail the
whole call; duplicate context keys fail even if their values are identical.
Already allocated input is not an ingress sandbox; no lazy streams are accepted.

Validation order is trusted shapes/bounds and duplicate keys; snapshot/window/
reservation consistency and graph budget; request shape/count/bytes; candidate
schema/hash/bytes/binding in occurrence order; combined identity bound and
conflicting duplicates. Errors contain safe schema atoms, not arbitrary content.

After validation, retrieval vetoes precede current binding/permission, freshness,
supersession, and derivation policy/provenance. Each node's own failure precedes
its source failures. Cyclic components fail closed after own checks; dependants
consume those failures. Among references the first failure in declared order
wins, independently of processing order. Successful child depths determine the
maximum path depth. An absent raw source differs from an unchecked source; an
existing evaluated-cache miss is an internal invariant failure, never a missing
node or permission grant.

Rank by enabled priority descending, enabled recency descending, then original
index ascending. Future `updated_at` has no special rejection behavior. Dedupe
eligible items by hash, otherwise item/version, in separate key domains. The first
eligible ranked duplicate wins even if it will not fit. A supplied newer version
prevents fallback to an older version even when the newer version is denied.

Packing checks **window fit, selected count, selected actual bytes**, in that
order, skipping rejected items and continuing. Zero-cost content still consumes
count. No optimal packing, maximal cardinality or permutation-invariant result
is promised. Equal inputs give equal output.

## Results and errors

```elixir
{:ok, %{
  selected: [selected_candidate],
  dropped: [%{index: index, item_id: id, version: version, reason: reason, detail: detail}],
  total_estimate: %{size: amount, unit: unit, estimator_id: id, estimator_version: version},
  reserved_estimate: amount, selected_count: count, selected_bytes: bytes,
  window: window, principal: id, tenant: id, evaluated_at: time
}}
{:error, {:invalid_input | :unavailable_context, reason}}
{:error, {:invariant_failed, :window | :access | :count | :bytes}}
```

Selected entries preserve input bytes/metadata and add `index`, `kind` (`:source`
or `:derived`) and `retrieval_access`. Their `access` becomes the current
three-field access record. Selected follows rank; dropped follows input occurrence
order. `total_estimate.size` excludes reservations. No error returns usable output.

| Reason | Details |
| --- | --- |
| `access_denied` | `retrieval_denied`, `principal_mismatch`, `binding_mismatch`, `missing_check`, `denied`, `source_unchecked`, `source_denied` |
| `stale_access_check` | `future_check`, `expired_check`, `source_stale` |
| `superseded` | `newer_version` |
| `over_window` | `insufficient_window` |
| `policy` | `missing_node`, `derived_disabled`, `superseded_source`, `cyclic_provenance`, `provenance_depth`, `duplicate`, `count_limit`, `byte_limit` |

Validation reasons include `{:missing_field, field}`, `{:unknown_field, field}`,
`:unknown_field`, `{:invalid_field, field}`, `{:bound_exceeded, bound}`,
`:duplicate_window`, `:duplicate_reservation`, `:duplicate_provenance_node`,
`:invalid_snapshot_time`, `:unknown_window`, `:window_mismatch`,
`:reservations_exceed_window`, `:hash_mismatch`, `:byte_estimate_underflow`,
`:candidate_binding_mismatch`, and `:conflicting_candidate`. Trusted faults use
`unavailable_context`; request/candidate faults use `invalid_input`. Expansion
4097 fails before evaluation with `unavailable_context/bound_exceeded` and bound
`:provenance_expansions`.

## Proof, runtime and test boundaries

Cure resolves versioned keys by first-match native comparisons against one
immutable raw list, preparing structural positions and every reference once.
Dependency scheduling uses positions, visited flags and bounded reachability for
cycle classification. It charges the entire scheduled node/reference set against
structural graph fuel before constructing verdicts. Tail-first memo evaluation
constructs exactly one final verdict per node. Missing cache entries fail closed.
Final guards recompute window, count, bytes and selected access from the result.
No runtime guard enumerates dependency paths.

The separate reference computation reads raw nodes/references rather than cached
node authority. `raw_schedule_law` relates prepared positional scheduling and cycle
classification to this raw traversal. It shares structural list/position helpers,
first-match resolution and primitive comparisons, not supplied correctness flags.
`resolution_law` independently connects resolved positions with raw first-match
node lookup, including missing keys. `prepared_node_law`, `prepared_edges_law` and
`prepared_position_law` connect preparation to the immutable list.

`memo_lookup_corresponds` relates actual memo entries to a recursive reference
evaluator over that raw graph and the preceding schedule suffix, including full
own binding/freshness, ordered source failures, cache faults and maximum depth.
The reference recursively recomputes dependencies; it is proof-side, not the
runtime algorithm. Own-access and source predicates are separately written from
the runtime guard/evaluator. `selected_access_law` instantiates the relation with
the internally generated schedule and the separate raw scheduler at its endpoint;
it assumes no cache/order correctness or safe-output Boolean. `selected_window`
relates the final guard to a separate sum/window predicate.

These are **safety laws for successful results over well-typed Cure inputs**.
The supported facade establishes the schema/encoding precondition; erased BEAM
helpers do not validate arbitrary foreign terms. The laws do not prove progress,
ranking, candidate membership, authentic checks or estimate accuracy. The
retrieval half of access is **test-grounded** in the facade veto and independent
reconstruction post-check. No M7 totality fallback is used.

Pinned Cure/BEAM native Int arithmetic/comparisons, String/binary equality,
structural lists and record erasure are upstream contracts. Symbolic native
comparison can remain neutral; no equality or arithmetic axiom is added. Finite
Unicode/digest/numeric comparison tests exercise the actual translation. OTP
`:crypto` supplies SHA-256; host provenance/snapshot authenticity is a Need.

Tests invoke production `select/2`: seven non-refusal requirements, revocation,
all authority overrides, malformed-input call seam, no-content Cure seam, binding,
provenance/order/depth/cycles, packing/dedupe/ranking, bounds, an independent small
DAG oracle and standalone original/renamed copies. Production mutations test
wrong cache/edges/resolution/cycle decisions and omitted access/window checks.
E2 always-refuse, E3 removed filter and E4 weakened guard **and spec** freshness
fail scenarios; E4's proofs still pass, illustrating their scope. Fabricated
selection and transitive-denial bypass also fail behavior assertions.

The 16×16 DAG has 256 nodes and 3840 edges. OTP call-count instrumentation checks
256 actual `node_verdict/5` constructions, and zero for the 4097 variant. Each
full call must finish below five seconds in the named test environment; this is
secondary, machine-bound evidence, not a service-level guarantee or proof of
4096 machine instructions. Instrumentation adds no production counter API.

## Copying and operations

Copy the manifest dependency closure using the catalogue exporter after registry
integration. Tests also compile exact copied source into a separate VM without the
root Application, then rename both modules/MFAs **and** `ContextSelection` record/
constructor tags. A redistributing library must use its own namespace and retest;
distinct Piece IDs alone do not prevent erased BEAM tag collisions. `local fn`
expresses intent, not BEAM privacy. Only the facade calls the Cure `select` entry.

Telemetry: not applicable to this pure call; the caller owns redacted observations.
Config: supported trusted per-call policy/window/reservations/caps; no hot update,
state revision or configuration persistence. Control: not applicable; no lifecycle,
business drain, delivery guarantee, storage or durable receipt is supplied.

The manifest records scoped grounding. Registry/ledger integration, full public
setup/check, exporter aggregate checks and independent final review remain
coordinator gates before task acceptance.
