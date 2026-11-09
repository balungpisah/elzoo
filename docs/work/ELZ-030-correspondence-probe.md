# ELZ-030 — R1 memo/spec correspondence feasibility

**Outcome: the reduced correspondence lemma checks on pinned Cure.** This is
an executable version of the planned dependency-order list-cache computation,
not full context-selection acceptance. Authority is the [focused clearance and
exact-SHA implementation specification](https://github.com/balungpisah/elzoo/issues/47#issuecomment-6713319785)
at `3bb189fadf24ce271dfe1709e6bb14c9e3a09ce9`, under R1-R8 and M1-M7.
The [implementation plan](ELZ-030.md) retains all unimplemented obligations.

## Representation and the exact claim

The scratch Cure module uses:

- `R1Node{id: String, own: Bool, refs: List(String)}`;
- `R1Entry{id: String, permitted: Bool}`;
- `build(nodes)`: recursively build the tail cache once, then compute and prepend
  the current node verdict once, reading only cached dependency verdicts;
- `cached_at(nodes, id)`: query that actual built cache with native String equality;
- `spec_at(nodes, id)`: separately implemented direct recursive evaluation, with
  no call to `build`, `cache_at`, `guard_refs` or `guard_and`.

The list stores dependants before their dependencies; **evaluation** is tail-first,
so dependencies execute first. At a matched node, the spec resolves its references
in the suffix of earlier evaluated nodes. For the intended unique, dependency-
ordered representation this is recursive evaluation of that DAG. Missing suffix
references fail closed. A cyclic or misordered input can therefore return false;
the probe does not classify missing nodes versus cycles versus cache misses.
It does not label an evaluated miss `missing_node` or permit on a miss.

The checked, no-hypothesis law is:

```text
for every well-typed nodes: List(R1Node), id: String:
  cached_at(nodes, id) = spec_at(nodes, id)
```

It has **no supplied cache, safety flag, correctness equation, permitted-result
assumption or equality axiom**. `own` is arbitrary data: the proof covers both
values, not an assumption that a node is permitted. It abstracts the node's own
binding/access/freshness gate solely to isolate the cache correspondence problem.
Production must compute that gate internally from trusted raw node/check fields;
there is no proposal to accept an untrusted `own` flag through the facade.

`cache_corresponds` inducts on the node list. `refs_correspond` inducts on a
reference list and invokes correspondence at the smaller dependency graph;
`hit_corresponds` cases on the actual native equality result. A small exhaustive
`join_corresponds` relates the separately written guard/spec Boolean conjunctions.
Cure checks this mutual structural recursion as total. The proof is not simply
reflexivity on a shared access predicate, nor an assumption of cache correctness.
Its list-induction technique follows the checked `blocked_anywhere` precedent in
`pieces/workflow/approval/cure/elzoo/approval.cure`.

### What depends on representation and upstream semantics

The theorem holds for arbitrary typed lists under the **ordered suffix** semantics,
including duplicate IDs, but the public Piece must reject duplicate provenance
node identities (even identical ones), reject conflicting candidate duplicates
and supply validated unique dependency order. It does not prove that an arbitrary input graph
was correctly topologically ordered or cycle-classified. That transformation is
assigned to Cure in the production plan and remains to be implemented, checked
and tested; silently dropping nodes/edges to obtain a convenient order is forbidden.
A link from this reduced representation to the complete raw-node specification is
still a production obligation. This feasibility result does not certify it.

Native equality is the actual pinned `Std.Builtin.struct_eq`, at inferred String
type; the normalizer leaves ADT/String equality neutral (`deps/cure/lib/cure/core/normalise.ex`,
`builtin_op_fold` for `struct_eq`). The proof branches on that computed result
and never claims `same(x, x) = True` by symbolic reduction. Both paths necessarily
share the native equality primitive, not their policy predicates. Its correctness
as String equality remains a pinned Cure/BEAM contract. Finite comparison tests
check 64 pairs against Elixir binary equality, including distinct Unicode byte
sequences; they do not prove native equality universally.

The nominal String ABI exercised here is `{:String, String.to_charlist(text)}`,
as used by the accepted Envelope translation. Valid UTF-8 is a facade precondition.
No proof is claimed for arbitrary erased BEAM tuples or direct helper access.

## Production use and exclusions

Production will build the cache once inside its Cure entry after deriving the
bounded dependency order, then use the same cached lookup/ordered-reference fold
for candidate access. The final access theorem must relate those returned candidate
verdicts to separately written raw-node/spec predicates by this structural pattern,
extended to exact `(item_id, version)` keys, full checks, failure reasons and depth.
The specification recursion is proof-side; it must not be executed per selected
candidate on the maximum shared DAG, which would reintroduce path expansion.

This probe is a Boolean permission projection, **not** first-failure reason
correspondence, full authority/freshness/provenance validation, numeric window
proof, selected caps, ranking, deduplication, candidate membership, source export,
or a proof of ordering/cycle detection. In particular, its false cache lookup
collapses denial and unresolved dependency; production must retain a distinct
cache lookup result and map an unexpected evaluated cache miss to fail-closed
`invariant_failed :access`, rather than `policy/missing_node`. Raw graph absence
is the separate per-item missing-node case. No accepted Contract changes here.

The graph has no separate fuel counter in this reduced ordered evaluator because
node/ref lists themselves strictly decrease. Production ordering/cycle passes
still require structural fuel and the fixed 4096 node-plus-edge pre-count. This
result does not select the M7 fallback; that fallback addresses recursive totality
only. A later correspondence failure must still be reported, never weakened.

## Executed evidence

Working directory for every command:
`<worktrees>/elzoo-ELZ-030`.
Initial local/remote head `3bb189fadf24ce271dfe1709e6bb14c9e3a09ce9`; fetched main
`367c83bba62fc891caaa60d1536cdc39de3cebbb`. Main was not merged for this pure
probe; no pin, dependency, protected file or existing test changed.
`git -C deps/cure rev-parse HEAD` returned
`a004c335cc4e9f2203ba6f51fc31e8540b66378d` (exit 0).
Elixir 1.20.4 / OTP 29.1.2; dependencies came from this worktree's prior setup.

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-r1/run.exs \
  > /tmp/elz030-r1/result.log 2>&1
```

Exit **0**. `Result: 16 passed` is the scratch runner count, not ExUnit or
`mix check`. Extraction from this document, SHA-256 checks and a second execution
with output `/tmp/elz030-r1/reproduced.log` also passed (exit 0, 16 passed,
256 constructions, 1218 microseconds versus the initial 1260 microseconds).
`git diff --check` and scoped local links passed; task/issue body stays unchanged.
The executable source and durable initial log follow. The three
mutations change actual cache/guard code only; the spec and laws stay unchanged.
They fail proof conversion, not parsing. The error context for two mutations
names the `join_corresponds` call inside `hit_corresponds`; the bad branch can no
longer transfer the guard value to the separately computed spec value.

A deterministic call counter (`:erlang.trace_pattern(..., [:call_count])`) counts
actual `entry_for/2` executions on the 256-node, 3840-edge shared DAG: exactly
256 verdict constructions. The spec is deliberately **not** run on that large
graph. Elapsed time is only a secondary observation for this reduced memo kernel;
it excludes production validation, ordering/cycle classification, hashing, bounds,
packing and reconstruction. It is not the task's full five-second timing gate.

The first two scratch attempts exited 1 for source-expression issues: record
construction is not parsed inside the theorem type, so an ordinary `entry_for`
helper now names it; and passing bare `String` as the explicit type argument to
`struct_eq` resolved its constructor, so the accepted repository's polymorphic
native-equality wrapper is used with String arguments. Neither was a native
correspondence failure, and no law was weakened. The next checker run succeeded.

```text
PASS structural cache/spec correspondence: check_source
PASS clean audit: %Cure.Audit.Ledger.Report{
  axioms: [],
  opaque: [],
  builtin_count: 22,
  holes: [],
  absurd: 0,
  not_proven_total: [],
  unresolved: [],
  unaudited: []
}
PASS compile_and_load
PASS scenario: allowed shared ancestor
PASS scenario: denied transitive ancestor
PASS scenario: own denied with permitted source
PASS scenario: absent query fails closed
PASS scenario: unresolved dependency fails closed
PASS scenario: out-of-order dependency fails closed
PASS scenario: cycle fails closed in ordered representation
PASS scenario: unicode IDs retain byte distinctions
PASS finite native String/Elixir binary agreement: 64 pairs
PASS memo kernel: 256 verdict constructions, 4096 graph units, 1260 us (<5 s); not full selector timing
PASS negative control: wrong_cached_true -> proof conversion failure at "join_corresponds"
PASS negative control: cache_miss_permits -> proof conversion failure at :cache_corresponds
PASS negative control: skip_reference_guard -> proof conversion failure at "join_corresponds"
Result: 16 passed (3 compiler/audit, 8 finite scenarios, 1 equality corpus, 1 counted memo benchmark, 3 proof negatives)
```

## Reproduce from embedded source

After pinned setup, extract the two exact source blocks, verify their hashes,
then run the command above. No database is used.

```python
from pathlib import Path
import re, hashlib
text = Path("docs/work/ELZ-030-correspondence-probe.md").read_text()
root = Path("/tmp/elz030-r1")
root.mkdir(parents=True, exist_ok=True)
for name in ["correspondence.cure", "run.exs"]:
    m = re.search(r"### " + re.escape(name) + r"\n\nSHA-256: `([^`]+)`\n\n```[^\n]+\n(.*?)```", text, re.S)
    assert m and hashlib.sha256(m[2].encode()).hexdigest() == m[1]
    (root / name).write_text(m[2])
```

### correspondence.cure

SHA-256: `7b5c7db64e769469b060a71644ed21a175ff3257449d9602709a5ac6714eff4f`

```cure
# SPDX-License-Identifier: Apache-2.0
# R1: tail-first memo evaluation versus a separate recursive ordered-graph spec.
mod Elzoo.ContextCorrespondenceProbe
  rec R1Node
    id: String
    own: Bool
    refs: List(String)
  rec R1Entry
    id: String
    permitted: Bool

  @total true
  @reducible
  local fn same(left: a, right: a) -> Bool = Std.Builtin.struct_eq(a, left, right)

  @total true
  @reducible
  local fn cache_at(cache: List(R1Entry), id: String) -> Bool =
    match cache
      [] -> False()
      [entry | rest] -> cache_at_with(entry, rest, id, same(entry.id, id))

  @total true
  @reducible
  local fn cache_at_with(entry: R1Entry, rest: List(R1Entry), id: String, hit: Bool) -> Bool =
    match hit
      True() -> entry.permitted
      False() -> cache_at(rest, id)

  @total true
  @reducible
  local fn guard_and(a: Bool, b: Bool) -> Bool =
    match a
      False() -> False()
      True() -> b

  @total true
  @reducible
  local fn guard_refs(cache: List(R1Entry), refs: List(String)) -> Bool =
    match refs
      [] -> True()
      [id | rest] -> guard_and(cache_at(cache, id), guard_refs(cache, rest))

  @total true
  @reducible
  local fn entry_for(node: R1Node, cache: List(R1Entry)) -> R1Entry =
    R1Entry{id: node.id, permitted: guard_and(node.own, guard_refs(cache, node.refs))}

  @total true
  @reducible
  local fn build_node(node: R1Node, cache: List(R1Entry)) -> List(R1Entry) =
    [entry_for(node, cache) | cache]

  # Stored dependants first, but execution evaluates dependencies/tail first.
  # build(rest) is passed once to build_node; node.own/refs are evaluated once.
  @total true
  @reducible
  fn build(nodes: List(R1Node)) -> List(R1Entry) =
    match nodes
      [] -> []
      [node | rest] -> build_node(node, build(rest))

  # Independent specification: no cache, build, guard_refs or guard_and calls.
  @total true
  @reducible
  local fn spec_and(a: Bool, b: Bool) -> Bool =
    match a
      False() -> False()
      True() -> b

  @total true
  @reducible
  fn spec_at(nodes: List(R1Node), id: String) -> Bool =
    match nodes
      [] -> False()
      [node | rest] -> spec_at_with(node, rest, id, same(node.id, id))

  @total true
  @reducible
  local fn spec_at_with(node: R1Node, rest: List(R1Node), id: String, hit: Bool) -> Bool =
    match hit
      True() -> spec_and(node.own, spec_refs(rest, node.refs))
      False() -> spec_at(rest, id)

  @total true
  @reducible
  local fn spec_refs(nodes: List(R1Node), refs: List(String)) -> Bool =
    match refs
      [] -> True()
      [id | rest] -> spec_and(spec_at(nodes, id), spec_refs(nodes, rest))

  @total true
  @reducible
  fn cached_at(nodes: List(R1Node), id: String) -> Bool = cache_at(build(nodes), id)

  @total true
  local fn join_corresponds(a: Bool, b: Bool) -> Equivalent(Bool, guard_and(a, b), spec_and(a, b)) =
    match a
      False() -> reflexive(False())
      True() -> reflexive(b)

  @total true
  local fn refs_correspond(nodes: List(R1Node), refs: List(String)) -> Equivalent(Bool, guard_refs(build(nodes), refs), spec_refs(nodes, refs)) =
    match refs
      [] -> reflexive(True())
      [id | rest] -> rewrite cache_corresponds(nodes, id) in rewrite refs_correspond(nodes, rest) in join_corresponds(spec_at(nodes, id), spec_refs(nodes, rest))

  @total true
  local fn hit_corresponds(node: R1Node, rest: List(R1Node), id: String, hit: Bool) -> Equivalent(Bool, cache_at_with(entry_for(node, build(rest)), build(rest), id, hit), spec_at_with(node, rest, id, hit)) =
    match hit
      True() -> rewrite refs_correspond(rest, node.refs) in join_corresponds(node.own, spec_refs(rest, node.refs))
      False() -> cache_corresponds(rest, id)

  # No safety/cache-correctness hypothesis; induction follows the actual build.
  @total true
  fn cache_corresponds(nodes: List(R1Node), id: String) -> Equivalent(Bool, cached_at(nodes, id), spec_at(nodes, id)) =
    match nodes
      [] -> reflexive(False())
      [node | rest] -> hit_corresponds(node, rest, id, same(node.id, id))
end
```

### run.exs

SHA-256: `c7f12ae546e41c78e195336fde106fdd4f6ee5d39fd78f00d680b5f685b27707`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
source = File.read!("/tmp/elz030-r1/correspondence.cure")
{:ok, env} = Cure.Compiler.check_source(source)
IO.puts("PASS structural cache/spec correspondence: check_source")
audit = Cure.Audit.Ledger.audit_env(env)
for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total] do
  [] = Map.fetch!(audit, key)
end
0 = audit.absurd
IO.inspect(audit, label: "PASS clean audit", limit: :infinity)
{:ok, mod} = Cure.Compiler.compile_and_load(source)
IO.puts("PASS compile_and_load")
s = fn text -> {:String, String.to_charlist(text)} end
node = fn id, own, refs -> {:R1Node, s.(id), own, Enum.map(refs, s)} end
allowed = [node.("root", true, ["left", "right"]), node.("left", true, ["leaf"]), node.("right", true, ["leaf"]), node.("leaf", true, [])]
denied = List.replace_at(allowed, 3, node.("leaf", false, []))
cases = [
  {"allowed shared ancestor", allowed, "root", true},
  {"denied transitive ancestor", denied, "root", false},
  {"own denied with permitted source", [node.("root", false, ["leaf"]), node.("leaf", true, [])], "root", false},
  {"absent query fails closed", allowed, "absent", false},
  {"unresolved dependency fails closed", [node.("root", true, ["missing"])], "root", false},
  {"out-of-order dependency fails closed", [node.("leaf", true, []), node.("root", true, ["leaf"])], "root", false},
  {"cycle fails closed in ordered representation", [node.("a", true, ["b"]), node.("b", true, ["a"])], "a", false},
  {"unicode IDs retain byte distinctions", [node.("α", true, ["é"]), node.("é", false, []), node.("é", true, [])], "α", false}
]
for {name, nodes, query, expected} <- cases do
  actual = apply(mod, :cached_at, [nodes, s.(query)])
  spec = apply(mod, :spec_at, [nodes, s.(query)])
  if actual != expected or spec != expected, do: raise("#{name}: #{inspect({actual, spec, expected})}")
  IO.puts("PASS scenario: #{name}")
end
texts = ["", "a", "b", "α", "é", "é", "same", "same\0suffix"]
for a <- texts, b <- texts do
  actual = apply(mod, :same, [s.(a), s.(b)])
  if actual != (a === b), do: raise("native equality disagreement")
end
IO.puts("PASS finite native String/Elixir binary agreement: 64 pairs")

# Trace the actual decision constructor without adding state to the result.
# The spec is never executed on this graph: it deliberately recomputes paths.
nodes = for layer <- 0..15, col <- 0..15 do
  refs = if layer == 15, do: [], else: for(next <- 0..15, do: "n#{layer + 1}:#{next}")
  node.("n#{layer}:#{col}", true, refs)
end
256 = length(nodes)
4096 = length(nodes) + Enum.sum(Enum.map(nodes, fn {:R1Node, _, _, refs} -> length(refs) end))
1 = :erlang.trace_pattern({mod, :entry_for, 2}, true, [:call_count])
{micros, cache} = :timer.tc(fn -> apply(mod, :build, [nodes]) end)
{:call_count, 256} = :erlang.trace_info({mod, :entry_for, 2}, :call_count)
1 = :erlang.trace_pattern({mod, :entry_for, 2}, false, [:call_count])
256 = length(cache)
true = Enum.all?(cache, fn {:R1Entry, _, permitted} -> permitted end)
true = micros < 5_000_000
IO.puts("PASS memo kernel: 256 verdict constructions, 4096 graph units, #{micros} us (<5 s); not full selector timing")

has_conversion? = fn
  {:conversion_failure, _, _} -> true
  {:branch_type, _, {:conversion_failure, _, _}} -> true
  _ -> false
end
for {name, from, to} <- [
  {"wrong_cached_true", "permitted: guard_and(node.own, guard_refs(cache, node.refs))", "permitted: True()"},
  {"cache_miss_permits", "      [] -> False()", "      [] -> True()"},
  {"skip_reference_guard", "guard_and(node.own, guard_refs(cache, node.refs))", "node.own"}
] do
  true = String.contains?(source, from)
  mutated = String.replace(source, from, to, global: false)
  {:error, {:source_context, reason, info}} = Cure.Compiler.check_source(mutated)
  true = has_conversion?.(reason)
  IO.puts("PASS negative control: #{name} -> proof conversion failure at #{inspect(info[:checking])}")
  File.write!("/tmp/elz030-r1/#{name}.error.txt", inspect({reason, info}, pretty: true, limit: :infinity))
end
IO.puts("Result: 16 passed (3 compiler/audit, 8 finite scenarios, 1 equality corpus, 1 counted memo benchmark, 3 proof negatives)")
```
