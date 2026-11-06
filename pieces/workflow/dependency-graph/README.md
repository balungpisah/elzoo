# workflow/dependency-graph

> **Stage 1 Contract draft (ELZ-026, issue #43). Not ready.** This file states
> the proposed Contract for early independent review. No implementation,
> proof or test exists yet, and the catalogue row stays `deferred` until the
> reviewed implementation lands. Nothing below is evidence.

A pure decision over caller-owned Work Item fixtures, typed prerequisite edges
and attributable satisfaction facts. It answers three questions from its inputs
only: which items are ready, which are blocked and why, and whether one proposed
blocking edge may be admitted without creating a cycle. It does not execute,
claim, lease, schedule, notify or persist anything. Item IDs and lifecycle tags
model a caller-owned record; this is not a durable Work Item implementation.

## Modules and providers

- Cure `Elzoo.DependencyGraph` (`:"Cure.Elzoo.DependencyGraph"`): the
  satisfaction, blocking and admission decisions and the selected laws.
- Elixir `Elzoo.DependencyGraph`: validating shell. It validates and bounds
  input, maps each ID to a dense node index in input order, calls the compiled
  Cure decisions, and builds the result and explanation from those calls.
- Providers: `cure`, `elixir`. Piece dependencies: none. This Piece consumes
  core/envelope, core/port and runtime/unit unchanged and uses none of them at
  runtime; it exports no Transition-shaped operator, so it has no core/operator
  dependency. No libgraph or other new dependency (see "libgraph boundary").

## Vocabulary and orientation

- **Node**: an item ID or a declared external prerequisite ID. IDs are nonempty
  valid UTF-8 binaries compared by exact byte equality, with no normalization.
  An ID's shape or tag establishes no authority or authenticity.
- **Edge** `%{from: dependant, to: prerequisite, kind: kind}`. Read
  `from -> to` as "`from` waits for `to`". `from` must be an item; `to` is an
  item or a declared external prerequisite.
- **Kinds**: `:blocking` participates in readiness and in cycle admission.
  `:informational` and `:hierarchy` never block, never enter the blocking
  graph and are never cycle-checked. They are carried for the caller only.
- **Cycle rule**: a proposed blocking `from -> to` creates a cycle iff `to`
  already reaches `from` over blocking edges, or `from == to`.
- **Explanation target**: every blocker's `target` is the edge's `to`, and the
  blocker is listed under the edge's `from`. The same orientation is used by
  readiness, explanation, validation and admission. No API reverses it.

## Inputs

```elixir
graph = %{
  items: [%{id: "a", lifecycle: :open, deferred_until: nil}, ...],
  externals: ["deploy-window", ...],          # declared non-item prerequisites (C7)
  edges: [%{from: "a", to: "b", kind: :blocking}, ...],
  facts: [%{prerequisite: "b", value: :satisfied, source: "ci-run-41",
            provenance: :tool_result, expiry: 1_767_225_600_000}, ...]
}
now = 1_767_225_000_000                       # Unix milliseconds, caller supplied
```

- **Lifecycle (task-local, frozen)**: `:open` (requested, not finished),
  `:completed` (accepted completion), `:cancelled` and `:closed` (closed
  without completion). The caller maps its own Work Item model onto these four
  tags. `:completed` means accepted completion as reported by the caller; this
  Piece does not check acceptance.
- **Deferral**: `deferred_until` is `nil` or a nonnegative integer Unix-ms.
  An item is deferred while `now < deferred_until`. Deferral is caller data.
- **Facts**: `value ∈ {:satisfied, :unsatisfied, :unknown}`; `source` is a
  nonempty UTF-8 ID; `provenance ∈ {:tool_result, :artifact_reference,
  :event_fold, :model_declared}`; `expiry` is a required nonnegative integer
  Unix-ms. There is no implicit unbounded fact. A fact is expired when
  `now >= expiry`. The host supplies provenance; the tag does not authenticate
  itself. Ingestion verification belongs to the caller's Adapter.
- **Time**: `now` is a nonnegative integer in Unix milliseconds. The decisions
  read no clock and perform no I/O.
- **Bounds**: at most 1_000 nodes, 10_000 edges and 10_000 facts. Larger input
  is rejected with `{:error, {:too_large, field}}` before evaluation, never
  truncated. Malformed input is rejected with `{:error, {:invalid, path}}`.

## Decisions

**Fact support for a target** (Cure `fact_support`): a fact *attributes* the
target when `value == :satisfied`, `now < expiry` and
`provenance != :model_declared`. A current (`now < expiry`) fact with
`value == :unsatisfied`, of any provenance, *vetoes* fact support. The target
has fact support iff at least one fact attributes it and none vetoes it.
`:unknown`, expired and model-declared-only facts never give support.

**Target satisfaction** (Cure `target_satisfied`), applied per blocking edge:

| Target | Satisfied | Reason when not |
| --- | --- | --- |
| item `:completed` | yes, regardless of facts | — |
| item `:cancelled` | never, regardless of facts | `:cancelled` |
| item `:closed` | never, regardless of facts | `:closed_without_completion` |
| item `:open` or external | iff fact support | first of: `:fact_vetoed`, `:model_declared_only`, `:fact_expired`, `:fact_unknown`, `:no_fact` |
| missing ID | never | `:unknown_dependency` |
| duplicate ID | never | `:duplicate_node` |
| unplaceable (cycle) | never | `:cycle` |

**Readiness** (Cure `item_ready`): an item is ready iff it is `:open`, not
deferred, not unplaceable, has a unique ID, and every blocking edge whose
`from` is the item is satisfied. Items that are not `:open` are neither ready
nor blocked; they are listed under `inactive`.

**Explanation**: for each open item that is not ready, `blockers` lists one
entry per unsatisfied blocking edge (or `:deferred`, `:duplicate_node`,
`:cycle` for the item itself), each computed by the same Cure
`target_satisfied` call that decides readiness. An item is ready iff its
blocker list is empty. The shell has no second predicate.

**Order**: `ready`, `blocked` and every node list keep the caller's input
order of `items` (then `externals`). The caller selects the order by ordering
its input. No priority policy is built in.

**Validation report**: three issue kinds that never collapse into one another:

- `%{kind: :duplicate_node, id: id}` per repeated ID across items and externals;
- `%{kind: :unknown_dependency, from: from, to: to}` per edge whose `to` is
  not a declared node, or whose `from` is not an item;
- `%{kind: :cycle, nodes: [id, ...]}`: every node that cannot be placed in a
  topological order of the blocking graph, that is, every cycle member and
  every node that transitively waits for one. Every unplaceable node is named;
  a topological order never appends them at its end.

## API

- `validate(graph)` → `{:ok, issues}` (issues may be `[]`) | `{:error, reason}`.
- `readiness(graph, now)` → `{:ok, %{ready: [id], blocked: [%{id: id,
  blockers: [%{target: id, present: boolean, satisfied: false, reason: atom}]}],
  inactive: [id], issues: issues}}` | `{:error, reason}`. `present` is false
  only for `:unknown_dependency`.
- `admit(graph, %{from: f, to: t, kind: k})` → `{:admit, graph2}` |
  `{:reject, reason}`. It revalidates the **whole** blocking graph with the
  proposed edge added. Reasons: `{:cycle, path}` where `path` is
  `[t, ..., f, t]` (the existing route from `t` to `f` plus the proposed edge;
  `[f, f]` for a self-loop), `{:invalid_graph, issues}` when the current graph
  already has issues, `{:unknown_dependency, ...}`. Non-blocking edges are
  admitted without a cycle check. Admission needs no `now`.
- `admission_step(graph, proposal)` → `{graph2, result}`: the pure step a
  volatile owner runs inside one serialized operation (see below).

## Concurrent admission design

Two edges can each pass a cycle check against the same snapshot and together
form a cycle. The safe pattern is one volatile owner (for example a GenServer
holding the graph) that runs `admission_step/2` for each proposal: it
revalidates the current whole blocking graph plus the proposal and commits the
result in the same serialized call. A check against a snapshot followed by a
separate commit, or two separate endpoint checks without one joint commit, is
not safe.

Test plan: a test-double owner serializes proposals; two racing, individually
plausible edges `a -> b` and `b -> a` are proposed concurrently. Exactly one is
admitted and the other is rejected with its cycle path. A negative-control
double (snapshot check, then separate commit) shows the cycle being committed
under a forced interleaving. This shows the listed in-process scenario only.
It is not a durable multi-head transaction or distributed agreement; durable
edges need an atomic storage Contract (ELZ-009 boundary).

## Grounding plan

**Proof (Cure laws over the actual decisions, checked by `mix check`)**:

- Satisfaction, by reduction, quantified over every other input: `:unknown`
  never attributes; `:unsatisfied` never attributes; an expired fact never
  attributes; a model-declared fact never attributes; `:cancelled` and
  `:closed` never satisfy for any fact support; `:completed` satisfies; an
  open or external target without fact support never satisfies.
- Blocking: `:informational` and `:hierarchy` edges never block, for every
  target state.
- Readiness, by induction over the blocker list: one unsatisfied blocking
  edge at any position makes the item not ready; a deferred or non-open item is
  never ready.
- Acyclicity: a self-loop is always rejected; and, quantified over every
  blocking edge list `es` and edge `e`, if `es` is acyclic under the Cure
  reachability definition and the actual Cure admission decision admits `e`,
  then `es ++ [e]` is acyclic. Nodes are dense Nat indices supplied by the shell.

**Known limitation and fallback**: the pinned Cure has structural induction,
`rewrite`, `simplify` and checked closed-term conversion. A spike outside the
repo confirmed that a closed reachability claim checks by conversion and that a
false closed claim fails with `conversion_failure`. The general acyclicity
proof is not yet shown to be completable at this pin. If it cannot be
completed, I will stop and report the exact limitation. One option for review
is an exhaustive kernel-checked law over every blocking graph on up to *k*
nodes, labelled exhaustive-over-*k* and never as a universal proof. That
fallback needs an explicit Contract decision; it is not assumed.

**Type/contract check**: the pinned Cure compiler checks the declarations.
Elixir callers of erased BEAMs are validated by the shell.

**Test (finite)**: the `now >= expiry` and `now < deferred_until` integer
comparisons; ID-to-index mapping; concurrent admission (above);
closed ≠ completed; expired fact; model-declared-only negatives; explanation
equals decision; the three issue kinds with every unplaceable node named;
cycle path shape; bounds and invalid input; an exhaustive comparison of
`admit` and `validate` against an independent Elixir reference over all
blocking graphs on small node counts; law audit and negative controls (a false
law and production mutations must fail compilation).

**Upstream contract**: pinned Cure compilation, reduction and runtime
semantics; Elixir 1.20.4 and OTP 29.1.2 execution and GenServer serialization
in the test double.

**Assumptions (unverified)**: callers supply truthful lifecycle tags,
provenance, sources and expiries, and a `now` translated from their clock;
clock skew is the caller's concern.

## Operations

- telemetry: **not_applicable**: pure decision; no execution to observe.
- config: **not_applicable**: no settings. Order, deferral, expiry and `now`
  are per-call data; bounds are fixed constants of this Contract.
- control: **not_applicable**: no process or lifecycle. The concurrency owner
  belongs to the caller.

## libgraph boundary

libgraph 0.17.1 (read from its documentation only; not added) offers
`is_acyclic?/1`, `topsort/1` (`[vertex] | false`, self-loops do not prevent an
order), `reachable/2` and `strong_components/1`. `add_edge` performs no cycle
check. `topsort/1` returning `false` does not name the unplaceable nodes, and a
library call cannot be the decision the Cure laws check. Ordinary graph code is
sufficient, so no dependency is proposed.

## Non-goals and unspecified behavior

- No execution, claiming, lease (ELZ-028), scheduling, notification, DAG
  templates or durable storage. No authentication of facts or provenance.
- Failure handling of a prerequisite (block/skip/fail per C5) is the caller's:
  this Piece reports `:cancelled` / `:closed_without_completion`; it never
  turns them into skip or fail.
- Cycles among informational or hierarchy edges are unspecified and unchecked.
- Multiple parallel blocking edges between the same pair are allowed and each
  is explained; duplicate edges are not an issue kind.
- Data classification: identifiers only.
