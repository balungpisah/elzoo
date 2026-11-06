# workflow/dependency-graph

Ready subset (ELZ-026, issue #43). Contract reviewed at `63e4dc6`
(early review, focused re-check and re-check 2 on #43). Lemma names in
the Cure source use the `Dg` prefix (`DgMem`, `DgWalk`, `dg_stay`,
`dg_hop`); the closure check is spelled `certifies` because `check` is a
reserved word in the pinned Cure. Laws 1, 4 and 5 are stated in equality
form (`… = False()`, or `True() = False()` from a cycle and a refutation)
because the ledger records only `Equivalent` proofs. Neither changes a law.

A pure decision over caller-owned Work Item fixtures, typed prerequisite edges
and attributable satisfaction facts. It answers three questions from its inputs
only: which items are ready, which are blocked and why, and whether one proposed
blocking edge may be admitted without creating a cycle. It does not execute,
claim, lease, schedule, notify or persist anything. Item IDs and lifecycle tags
model a caller-owned record; this is not a durable Work Item implementation.

## Modules and providers

- Cure `Elzoo.DependencyGraph` (`:"Cure.Elzoo.DependencyGraph"`): the
  satisfaction, readiness and admission decisions and the selected laws. The
  compiled BEAM may import only `:erlang`. Proof helpers are local, so the
  copied decision needs no Cure standard-library BEAM at runtime. A test
  asserts the import list.
- Elixir `Elzoo.DependencyGraph`: validating shell. It validates and bounds
  input, maps IDs to integer node indices, calls the compiled Cure decisions,
  and maps the results back to IDs. It computes only the rows marked Elixir in
  the table below.
- Providers: `cure`, `elixir`, `otp` (OTP only in the test double).
- Piece dependencies: `core/operator`, because the Cure step
  `:"Cure.Elzoo.DependencyGraph".admission_step/2` returns its
  `Elzoo.Composition.Transition`. `runtime/unit` is used by the test double
  under `test/` only (see "Concurrent admission"). Envelope, Port and Unit are
  consumed unchanged. No libgraph and no other new dependency.

## Vocabulary and orientation

- **Node**: an item ID or a declared external prerequisite ID. IDs are nonempty
  valid UTF-8 binaries compared by exact byte equality, with no normalization.
  An ID's shape or tag establishes no authority or authenticity.
- **Edge** `%{from: dependant, to: prerequisite, kind: kind}`. Read
  `from -> to` as "`from` waits for `to`". `from` must name an item; `to`
  names an item or a declared external prerequisite.
- **Kinds**: `:blocking` participates in readiness and in cycle admission.
  `:informational` and `:hierarchy` never block, never enter the blocking
  graph and are never cycle-checked.
- **Cycle rule**: a proposed blocking `from -> to` creates a cycle iff `to`
  already reaches `from` over blocking edges, or `from == to`.
- **Explanation target**: every blocker's `target` is the edge's `to`, listed
  under the edge's `from`. Readiness, explanation, validation and admission use
  this one orientation. No API reverses it.

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
  tags. This Piece does not check acceptance.
- **Deferral**: `deferred_until` is `nil` or a nonnegative integer Unix-ms.
  An item is deferred while `now < deferred_until`.
- **Facts**: `value ∈ {:satisfied, :unsatisfied, :unknown}`; `source` is a
  nonempty UTF-8 ID; `provenance ∈ {:tool_result, :artifact_reference,
  :event_fold, :model_declared}`; `expiry` is a required nonnegative integer
  Unix-ms (no implicit unbounded fact). A fact is **current** when
  `now < expiry` and **expired** when `now >= expiry`. The host supplies
  provenance; the tag does not authenticate itself. Ingestion verification
  belongs to the caller's Adapter.
- **Time**: `now` is a nonnegative integer in Unix milliseconds. No decision
  reads a clock or performs I/O.
- **Bounds**: nodes (items + externals) ≤ 1_000; edges ≤ 10_000; facts ≤
  10_000. For `admit` and `admission_step`, the proposed edge counts toward the
  edge limit. Larger input fails with exactly
  `{:error, {:too_large, :nodes | :edges | :facts}}` before evaluation. Input is
  never truncated.
- **Malformed input** fails with `{:error, {:invalid, path}}`, where `path`
  is a list such as `[:items, 3, :lifecycle]`, `[:facts, 0, :expiry]`,
  `[:now]` or `[:proposal, :kind]`. Bounds are checked first, then
  well-formedness.

## Where each decision is computed

| Function | Computed in | Grounding |
| --- | --- | --- |
| ID → index mapping (input order); an undeclared `from` or `to` maps to the reserved index `-1` | Elixir | test only |
| Cure edge list = every edge of the graph, same order, as `RE(kind, from, to)` | Elixir | test only |
| bounds and well-formedness | Elixir | test only |
| duplicate-node and unknown-dependency detection | Elixir | test only; supplied to Cure as per-node flags |
| unplaceable nodes (Kahn residual over valid blocking edges) | Elixir | test only; supplied to Cure as per-node flags |
| node lookup by index (builtin equality) | Cure | test only |
| Elixir `admission_step/2`: map IDs to indices, call the Cure step, commit the Cure `next` mapped back to IDs | Elixir | test only |
| fact current/expired (`now < expiry`) | Cure, builtin `Int` comparison | law over the comparison's result; the comparison's integer meaning is an upstream Cure/BEAM contract plus boundary tests |
| `attributes` (one fact) | Cure | laws (satisfaction) |
| `fact_support` (target over the **full** fact list, filtering by target index in Cure) | Cure | list-induction law "unknown never satisfies" |
| `target_satisfied` (lifecycle × fact support) | Cure | laws |
| deferral (`now < deferred_until`) | Cure, builtin comparison | as for expiry |
| `item_ready` (over the **full** edge list; per edge, `kind` is tested **before** the builtin endpoint comparison `from == i`) | Cure | laws 3–4, over the Bool result of builtin equality |
| blocker reason and priority (only for edges whose Cure `target_satisfied` is false; currentness via Cure `current/2`) | Elixir | test only |
| `completion_contradicted` detection (currentness via Cure `current/2`) | Elixir | test only |
| reachability search for admission | Cure | not trusted by the law; completeness test only |
| `blocking` projection (`List(REdge)` → `List(Edge)`) | Cure | law 5a |
| `admits` (closure certificate check) and the Cure `admission_step` | Cure | laws 5–6 |
| cycle path in a rejection, and `:search_disagreement` | Elixir BFS | test only |

The Cure library order `Std.Proof.IntOrder.le_int` was probed for expiry. Its
runtime cost is linear in the integer's size (about 2.6 ms per 10^6). One
Unix-ms comparison took more than 120 s and was stopped. So the decision uses
the builtin comparison, and the law quantifies over its Boolean result. This is
the same pattern as the builtin ID equality. The law does not cover the
builtin's arithmetic meaning; that is upstream contract plus boundary tests at
`expiry - 1`, `expiry` and `expiry + 1`.

## Decisions

**One fact.** A fact *attributes* its target iff `value == :satisfied`, it is
current, and `provenance != :model_declared`. A current fact with
`value == :unsatisfied`, of any provenance, *vetoes*.

**Fact support for a target**: at least one fact for the target attributes
it, and no fact for the target vetoes. Facts for other targets are ignored.
So a model can block work (a model-declared veto), but a model can never
unblock work.

**Target satisfaction**, per blocking edge. The rows are checked in this
order, and the first that applies decides: undeclared, then duplicate, then
unplaceable, then lifecycle, then facts.

| Order | Target | Satisfied |
| --- | --- | --- |
| 1 | undeclared `to` | never |
| 2 | duplicate ID | never, whatever its lifecycle |
| 3 | unplaceable | never, whatever its lifecycle |
| 4 | unique, placeable item `:completed` | yes (accepted completion, per #43). A current veto also produces a `:completion_contradicted` entry. It does not change readiness. |
| 4 | unique, placeable item `:cancelled` | never, regardless of facts |
| 4 | unique, placeable item `:closed` | never, regardless of facts |
| 5 | unique, placeable item `:open`, or external | iff fact support |

`:completion_contradicted` applies only to unique, placeable completed
targets. A duplicate or unplaceable completed target is unsatisfied, with
reason `:duplicate_node` or `:cycle`, and has no contradiction entry.

**Blocker reasons**, one per unsatisfied blocking edge. Each is a predicate
over the target and the facts for that target. The first that holds is used:

1. `:unknown_dependency`: `to` is not a declared node (`present: false`).
2. `:duplicate_node`: `to` is declared more than once.
3. `:cycle`: `to` is unplaceable.
4. `:cancelled` / `:closed_without_completion`: `to` is an item with that tag.
5. `:fact_vetoed`: a current `:unsatisfied` fact exists for `to`.
6. `:model_declared_only`: a current `:satisfied` fact exists for `to`, and
   every current `:satisfied` fact for `to` is model-declared.
7. `:fact_unknown`: a current `:unknown` fact exists for `to`.
8. `:fact_expired`: facts for `to` exist, and all of them are expired.
9. `:no_fact`: no fact exists for `to`.

Example: an expired satisfied tool result plus a current satisfied
model-declared fact gives `:model_declared_only`. An open item `to` with no
attributing fact uses reasons 5–9 the same way. An item's own state adds
entries with `target` equal to its own ID: `:deferred`, `:duplicate_node`,
`:cycle` (when the item itself is unplaceable).

`present` is `false` only for reason 1. It is `true` for reasons 2–9 and for
every own-state entry.

**Readiness**: an item is ready iff it is `:open`, not deferred, has a unique
ID, is placeable, and every blocking edge whose `from` is the item is
satisfied. Items that are not `:open` are neither ready nor blocked; they are
listed under `inactive`.

**Explanation**: for each open item that is not ready, `blockers` lists every
entry above in this order: first the item's own-state entries, in the fixed
order `:deferred`, `:duplicate_node`, `:cycle`; then one entry per unsatisfied
blocking edge from the item, in `graph.edges` order. `admit` prepends, so the
newest admitted edge's blocker comes first among the edge entries. A test checks
this order. An item is ready iff its blocker list is empty; a test checks this
for every item in every listed scenario. `contradictions` lists each
`%{item: from, target: to, reason: :completion_contradicted, sources: [source]}`
for completed targets with a current veto, on ready and blocked items alike.

**Order**: `ready`, `blocked`, `inactive` and every node list keep the
caller's input order of `items`, then `externals`. The caller selects the order
by ordering its input.

**Validation report**: three issue kinds that never collapse:

- `%{kind: :duplicate_node, id: id}`, once per repeated ID across items and
  externals;
- `%{kind: :unknown_dependency, from: from, to: to, endpoints: %{from: role, to: role}}`
  with `role ∈ {:item, :external, :undeclared}`, per edge (every kind) whose
  `from` is not `:item` or whose `to` is `:undeclared`. A `from` that is a
  declared external has role `:external`, distinct from `:undeclared`;
- `%{kind: :cycle, nodes: [id, ...]}`: every node that cannot be placed in a
  topological order of the valid blocking edges. That is every cycle member and
  every node that transitively waits for one. Every unplaceable node is named;
  an order never appends them at its end.

Edges with an unknown dependency are excluded from the blocking graph used for
placement. A blocking edge whose `from` is an item and whose `to` is
undeclared still blocks that item, with `present: false`. Other unknown-
dependency edges block nothing; they appear only in `issues`.
Facts whose `prerequisite` is not a declared node are ignored by every
decision. They are listed under `orphan_facts: [index]` and are not an issue
kind.

## API

- `validate(graph)` → `{:ok, issues}` (possibly `[]`) | `{:error, reason}`.
- `readiness(graph, now)` → `{:ok, %{ready: [id], blocked: [%{id: id,
  blockers: [%{target: id, present: boolean, satisfied: false, reason: atom}]}],
  inactive: [id], contradictions: [map], orphan_facts: [index], issues: issues}}`
  | `{:error, reason}`.
- `admit(graph, %{from: f, to: t, kind: k})` returns the first that applies,
  in this order:
  1. `{:error, {:too_large, _} | {:invalid, path}}` for an oversized or
     malformed graph or proposal;
  2. `{:reject, {:invalid_graph, issues}}` when the current graph already has
     any issue;
  3. `{:reject, {:unknown_dependency, %{from: f, to: t, endpoints: %{from: role, to: role}}}}`;
  4. for `:blocking` only: `{:reject, {:cycle, path}}`, where `path` is
     `[t, ..., f, t]`: a shortest existing route of blocking edges from `t` to
     `f`, then the proposed edge. A self-loop gives `[f, f]`. Which shortest
     route is returned when several exist is unspecified. The Contract and its
     test cover the shape (starts and ends at `t`, consecutive blocking edges of
     the graph, contains `f`) and the minimal length;
  5. `{:error, :search_disagreement}` when the Cure decision rejects but the
     Elixir BFS finds no route from `t` to `f` (a defective search; see law 5);
  6. otherwise `{:admit, graph2}`, where `graph2.edges` is the proposed edge
     **prepended** to `graph.edges`, mapped back from the Cure `next`.

  It revalidates the **whole** graph with the proposed edge added. Endpoint
  validation applies to every kind; only `:blocking` proposals get the cycle
  check. Edge order has no meaning for any decision; it only orders blocker
  lists (see Explanation). Admission needs no `now`. On reject or error the caller's graph is not
  changed and no graph is returned.
- Two `admission_step` functions, one per layer:
  - **Cure** `:"Cure.Elzoo.DependencyGraph".admission_step(es, proposal)`
    works on the index-level edge list `List(RE(kind, from, to))` and returns
    `Elzoo.Composition.Transition(List(REdge), Verdict)`. For a `:blocking`
    proposal `RE(:blocking, f, t)` it decides with `admits(blocking(es), f, t)`,
    where `blocking` is a Cure function keeping only blocking edges as
    `E(from, to)`. If that is true, `next = [proposal | es]` and the verdict is
    admit; otherwise `next = es` and the verdict is reject. For a non-blocking
    proposal, `admits` and `check` are not called: the verdict is admit and
    `next = [proposal | es]`. Laws 5, 5a and 6 are about this function.
  - **Elixir** `Elzoo.DependencyGraph.admission_step(graph, proposal)` is
    what `Elzoo.Unit.step/2` runs. It validates, maps IDs to indices, calls the
    Cure step, and commits the Cure `next` mapped back to IDs. It does not build
    the next graph by its own logic. It returns
    `{:Transition, next_graph, {:some, result}}`, where `result` uses the same
    atoms as `admit/2` without the graph: `:admit`, `{:reject, reason}` or
    `{:error, reason}`. On anything other than `:admit`, `next_graph` is the
    input graph unchanged. This layer is test-only (see the table).

## Concurrent admission

Two edges can each pass a cycle check against the same snapshot and together
form a cycle. The safe pattern is one volatile owner holding the graph. For
each proposal it runs the Elixir `admission_step/2`, which revalidates the current whole
blocking graph plus the proposal and commits the Cure step's `next` in the
same serialized call. A snapshot check followed by a separate commit, or two separate endpoint
checks without one joint commit, is not safe.

Test plan, under `test/` only: an `Elzoo.Unit` started with
`{Elzoo.DependencyGraph, :admission_step, graph}` is the serialized owner. Two
tasks race the individually plausible edges `a -> b` and `b -> a`. Exactly one
is admitted; the other is rejected with its cycle path; the final graph is
acyclic. A negative-control double reads a snapshot, checks with `admit/2`,
then commits separately. Under a forced interleaving it commits both edges, and
the test confirms that the result has a cycle. This shows the listed
in-process scenario only. It is not a durable multi-head transaction or
distributed agreement. Durable edges need an atomic storage Contract (ELZ-009
boundary). No owner process is a ready source of this Piece.

## Grounding

### Proof: selected Cure laws over the actual decisions

Every function in `cure/elzoo/dependency_graph.cure` carries `@total true`
(a test checks this). Without it, the pinned Cure accepts a non-terminating
proof. The test file runs 16 negative controls (mutations that the kernel
must reject, each in a named function) and the Cure audit (no axioms, holes,
unresolved, unaudited, opaque or not-proven-total entries). Symbols are listed
in [piece.json](piece.json).

1. **"Unknown never satisfies" (#43), list induction.** An inductive
   predicate `Unattributed(facts, target, now)` holds for the full fact list
   when every element is one of: a fact for another target; an `:unknown`
   fact; an `:unsatisfied` fact; a model-declared fact; or an expired fact.
   "Other target" and "expired" carry explicit Bool evidence:
   `Equivalent(Bool, id == target, False())` and
   `Equivalent(Bool, now < expiry, False())`. The law is: for every fact list
   and target with `Unattributed`, the actual `fact_support` is false. Its
   scope is over the Bool results of builtin equality and order.
   Symbol `unknown_never_satisfies`. Negative controls: a model-declared,
   unknown or always-current fact that attributes (`branch_type`).
2. **Satisfaction table**, by reduction, over every other input: an
   undeclared, duplicate or unplaceable target never satisfies, whatever its
   lifecycle; a unique, placeable `:cancelled` or `:closed` target never
   satisfies for any fact list; a unique, placeable `:completed` target
   satisfies; a single `:unknown`, `:unsatisfied`, expired or model-declared
   fact never attributes.
3. **Blocking**: `item_ready` tests an edge's `kind` before its endpoint. So
   an `:informational` or `:hierarchy` edge leaves `item_ready` unchanged:
   `item_ready(i, [RE(k, f, t) | es]) ≡ item_ready(i, es)` for non-blocking
   `k` and every `f`, `t` (reduction).
4. **Readiness**, by induction over the full edge list. The hypothesis is an
   inductive `BlockedBy(es, i, …)`: some element is `RE(:blocking, from, to)`
   with `Equivalent(Bool, from == i, True())` and
   `Equivalent(Bool, target_satisfied(to, …), False())`. Then `item_ready`
   is false. Its scope is over the Bool result of builtin equality. A deferred,
   non-open, or flagged duplicate or unplaceable item is never ready
   (reduction).
   Negative controls: an informational edge that blocks
   (`informational_never_blocks`), a blocking edge treated as satisfied
   (`pick_head`), and deferral ignored (`open_blocked`).

   **Corollary of laws 1, 2 and 4** (not a separate checked law): an open or
   external, unique, placeable target with only unattributed facts is not
   satisfied (laws 1 and 2). So any item with a blocking edge to it is not
   ready (law 4).
5. **Acyclicity preservation.** `Walk(es, a, b)` is an inductive path
   relation, independent of the admission search (`walk_nil`, and
   `walk_cons : Mem(es, E(a, m)) -> Walk(es, m, b) -> Walk(es, a, b)`). A
   cycle is an edge `E(x, m)` in `es` plus a walk from `m` to `x`. The
   admission decision is `admits(es, f, t) = check(es, f, t, search(es, t))`.
   `check(es, f, t, s)` accepts only when the candidate set `s` contains `t`,
   is closed under every edge of `es`, and does not contain `f`. The law: for
   every `es`, `f`, `t` and every `s` with `check` true, every cycle of
   `[E(f, t) | es]` is a cycle of `es` with the same first edge. So admission
   preserves acyclicity, self-loops included. The ledger records proofs in
   equality form, so the checked statement is: a `DgCycle` through `E(x, m)`
   in the new graph, plus a refutation `(DgCycle(es, x, m)) -> True = False`
   for the old graph, proves `True = False`. The law holds for every `s`, so
   the search is not trusted. A defective search can only cause a false
   rejection, never a cycle; the Elixir layer reports that case as
   `{:error, :search_disagreement}`.
   **Over the committed state:** when the Cure `admission_step` admits a
   blocking proposal, every cycle of `blocking(next)` is a cycle of
   `blocking(es)`. This follows from the law above with `es := blocking(es)`
   and law 5a. A non-blocking admission leaves `blocking(next) ≡ blocking(es)`
   (law 5a), so it adds no cycle.
   Symbols `admitted_keeps_acyclic` and `admission_keeps_acyclic`. Negative
   controls: dropping the "does not contain `f`" conjunct
   (`new_cycle_contradicts`), a `closed` that skips an edge (`closed_mem`),
   a projection that drops a blocking edge (fails in the committed-state law,
   `committed_cycle_inner`), and a non-structural recursion
   (`total_required_by_decorator`).
5a. **Projection (checked reductions).**
   `blocking([RE(:blocking, f, t) | es]) ≡ [E(f, t) | blocking(es)]`, and
   `blocking([RE(k, f, t) | es]) ≡ blocking(es)` for `k ∈ {:informational,
   :hierarchy}`, for every `f`, `t`, `es`. A negative control (a projection
   that keeps an informational edge) fails in `blocking_drops_informational`.
6. **Unchanged on reject**: for a blocking proposal, the Cure `admission_step`
   returns its input state `es` whenever `admits(blocking(es), f, t)` is false
   (reduction over Bool evidence of that result). Non-blocking proposals are
   always admitted, so law 6 does not apply to them.

All of laws 1–6 (with 5a) are about the Cure functions. The Elixir mapping and commit
layer around them is test-only.

**Not proved (F9):** #43 says "admitted **iff** the target cannot already
reach the source". The laws prove only the safe direction: admitted implies
acyclic. The converse (an acyclic result is always admitted, meaning the
search is complete within its fuel) is a finite test against an independent
Elixir reachability reference: every acyclic blocking graph on 2 and 3 nodes
(self-loops included) with every proposal; the 543 acyclic graphs on 4 nodes
without self-loops with every non-loop proposal; 60 random 30-node acyclic
graphs; and a 1,000-node chain. That test also requires that
`{:error, :search_disagreement}` never occurs. Nobody should read the "iff" as
proved.

### Type/contract check

The pinned Cure compiler checks the declarations, including the Transition
type from core/operator. Erased Elixir callers are validated by the shell.

### Test (finite)

Boundary comparisons for expiry and deferral; ID mapping; bounds and every
exact error; the three issue kinds with every unplaceable node named; edges
with unknown dependencies excluded from placement; orphan facts; reason
predicates and their priority (including the example above); `present`
values; the `:external` vs `:undeclared` endpoint roles; closed ≠ completed;
a duplicate completed target and an unplaceable completed target are both
unsatisfied without a contradiction entry; expired fact; model-declared-only
negatives; model veto blocks; `:completion_contradicted` reported without
changing readiness; explanation equals decision for every item; `admit` reject
precedence (error, then `:invalid_graph`, then `:unknown_dependency`, then
`:cycle`); cycle path shape and minimal length; blocker order (own-state entries, then edges in `graph.edges` order, newest admitted first); the Elixir step commits exactly the mapped Cure
`next`; concurrent admission and its negative control; search completeness and
no `:search_disagreement` (above); the compiled BEAM import list; the law audit
and negative controls.

### Upstream contract

Pinned Cure (`a004c335…`) compilation, kernel checking, totality checking and
runtime semantics, including builtin `Int` equality and order. Elixir 1.20.4
and OTP 29.1.2 execution, and GenServer call serialization in the test double.

### Assumptions (unverified)

Callers supply truthful lifecycle tags, provenance, sources and expiries, and
a `now` translated from their clock. Clock skew is the caller's concern.

## Copy and limits

Select `workflow/dependency-graph` with `mix elzoo.take`; see
[consuming](../../../docs/consuming.md). The copied decision needs the
compiled Cure BEAM and the Elixir shell, not Cure.Compiler or the Cure
standard library at runtime. `runtime/unit` is needed only by the copied test.

- No join/fan-in policy beyond "every blocking prerequisite satisfied"; no
  skip/fail handling, execution, claiming, lease, scheduling or storage.
- No performance claim. One observation on the worker laptop: readiness at
  full bounds (1,000 items, 9,987 blocking edges, 10,000 facts) took about
  6.7 s, and one admission about 0.2 s.

## Operations

- telemetry: **not_applicable**: pure decision; no execution to observe.
- config: **not_applicable**: no settings. Order, deferral, expiry and `now`
  are per-call data; bounds are fixed constants of this Contract.
- control: **not_applicable**: no process or lifecycle. The serialized owner
  is a test double under `test/` and is not a ready source. If an owner is
  ever shipped, Control and Telemetry must be re-declared (`planned` or
  `supported`) under the evolution rule.

## Deltas against #43 (recorded on the issue)

1. **`externals` input.** #43 lists only items as nodes. C7 needs time or
   trigger prerequisites that are not Work Items. Declaring them explicitly
   keeps `:unknown_dependency` separate from "missing fact".
2. **Ordering policy = input order.** #43 names "the ordering policy" as an
   input. This Contract fixes it to the caller's input order and builds in no
   priority policy. A caller chooses any policy by ordering its input.
3. **core/operator.** #43 §6 says "depends on core/operator". `admission_step`
   returns core/operator's `Transition`, so the dependency is kept. Readiness
   and validation are plain functions, not Operators: they hold no state.
4. **`:completion_contradicted`.** #43 says an accepted completion satisfies.
   That is kept (only for a unique, placeable target; see delta 7). A current veto on a completed target is reported as a
   distinct contradiction entry. It does not change readiness.
5. **Iff, safe direction only.** The acyclicity law proves admitted ⇒ acyclic.
   The completeness direction is a finite test (see "Not proved").
6. **Expiry comparison.** It is computed in Cure with the builtin comparison.
   The law covers its Boolean result, not its integer meaning, because the
   proof-carrying library comparison is unusable at runtime for Unix-ms values.
   The same scope applies to the builtin endpoint equality in laws 1 and 4.
7. **Satisfaction order.** #43 says an accepted completion satisfies. This
   Contract applies that only to a unique, placeable completed target. A
   duplicate or unplaceable completed target fails closed.

## libgraph boundary

libgraph 0.17.1 (read from its documentation only; not added) offers
`is_acyclic?/1`, `topsort/1` (`[vertex] | false`; self-loops do not prevent an
order), `reachable/2` and `strong_components/1`. `add_edge` performs no cycle
check. `topsort/1` returning `false` does not name the unplaceable nodes, and a
library call cannot be the decision the Cure laws check. Ordinary graph code is
sufficient, so no dependency is proposed.

## Non-goals and unspecified behavior

- No execution, claiming, lease (ELZ-028), scheduling, notification, DAG
  templates or durable storage. No authentication of facts or provenance.
- Prerequisite failure handling (block/skip/fail per C5) is the caller's. This
  Piece reports `:cancelled` / `:closed_without_completion`; it never turns
  them into skip or fail.
- Cycles among informational or hierarchy edges are unspecified and unchecked.
- Parallel blocking edges between the same pair are allowed and each is
  explained. Duplicate edges are not an issue kind.
- Data classification: identifiers only.
