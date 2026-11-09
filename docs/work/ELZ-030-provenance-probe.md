# ELZ-030 — Recursive provenance feasibility, revision two

This is a scratch feasibility probe, not production source or acceptance of the
full [revised Contract](ELZ-030.md). It adapts the independent reviewer's probe P
(Orca `0f974e4c-75e1-4daf-9a19-7720ad2b1633`), adding `local fn` declarations,
assertions, a guard-mutation control and an export-limit observation. The original
review and authority are linked in the revised proposal. No external code or
new dependency is copied into a ready Piece.

## Exact scope

The probe exercises mutual recursion over node references with a **structural
fuel list**, not an integer termination claim. It checks one quantified
successful-result provenance law, compiles the code, audits checked totality,
and tests allowed/denied transitive nodes, missing check, missing node, a cycle
and insufficient depth fuel. It also confirms a `local fn` helper remains a
BEAM export: only the future validated facade is the supported API.

It intentionally does not run the maximum layered DAG: this reduced recursive
shape revisits shared paths and is not the bounded production algorithm. The
production plan is mandatory **memoization plus budget**: pre-count the whole
node+edge set up to 4096, compute one verdict/depth per node in dependency order,
consume structural fuel on each new node/edge expansion, and reuse cached verdicts.
Cycles need bounded classification; reference-order failure reporting cannot be
changed by cache order. The 16×16 graph is exactly 256+3840=4096, and an extra
leaf-to-leaf edge gives 4097, rejected before depth evaluation. The exact planned
five-second test gate and lookup accounting are in the revised proposal.

This probe proves neither that memoized algorithm nor its cache correspondence,
String/tenant/hash bindings, node completeness, output caps or facade validation.
It shares `ok_ids` between guard and result predicate; it is **not** evidence
for the revised separately written production predicates. Production must
connect the actual result, raw current checks and transitive provenance with
checked structural lemmas; a failure cannot be hidden behind a weaker helper
law. If recursive totality cannot be checked, the approved M7 fallback moves
closure into Elixir, with exactly the same limits and behavior tests, and calls
closure correctness test-grounded while Cure checks flat ancestor permissions.
No fallback is silently selected here.

## Command and observed evidence

Working directory: `<worktrees>/elzoo-ELZ-030`.
Cure `a004c335cc4e9f2203ba6f51fc31e8540b66378d`, already built in this worktree
by stage-one setup; Elixir 1.20.4 / OTP 29.1.2. No pin or dependency change.

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-r2/provenance.exs \
  > /tmp/elz030-r2/provenance.log 2>&1
```

Exit **0**. The count is a scratch runner marker, not `mix check` or ExUnit.
The exact embedded sources were extracted, hash-matched and rerun with output to
`/tmp/elz030-r2/reproduced.log`: also exit 0, the same `Result: 11 passed`.
The durable log is embedded here; `/tmp` is only a reproduction location.

```text
PASS recursive prov_law: check_source
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
PASS scenario: transitive allowed
PASS scenario: transitive denied
PASS scenario: missing source check
PASS scenario: missing source node
PASS scenario: cycle exhausts structural fuel
PASS scenario: insufficient depth fuel
PASS guard-bypass negative: conversion_failure at :pfinish_prov
PASS observed limit: local helper remains a BEAM export (not privacy)
Result: 11 passed (3 compiler/audit, 6 finite scenarios, 1 proof negative, 1 export-limit observation)
```

## Reproduce the exact sources

Extract the two blocks below after pinned setup, then run the command above:

```python
from pathlib import Path
import re, hashlib
text = Path("docs/work/ELZ-030-provenance-probe.md").read_text()
root = Path("/tmp/elz030-r2")
root.mkdir(parents=True, exist_ok=True)
for name in ["provenance.cure", "provenance.exs"]:
    m = re.search(r"### " + re.escape(name) + r"\n\nSHA-256: `([^`]+)`\n\n```[^\n]+\n(.*?)```", text, re.S)
    assert m and hashlib.sha256(m[2].encode()).hexdigest() == m[1]
    (root / name).write_text(m[2])
```

### provenance.cure

SHA-256: `215caca8cd65f467764ffdc9ed22eeb8daa571e0ab8691c020b1a5a9951e6c92`

```cure
# SPDX-License-Identifier: Apache-2.0
# Reduced feasibility, adapted from reviewer 0f974e4c probe P.
# Mutual recursion terminates by structural fuel and list recursion.
# Not production: no memoization or global expansion accounting here.
# Production plan: pre-count nodes+edges <=4096; dependency-order node cache,
# one verdict/depth per node; consume structural fuel only on new expansion.
mod Elzoo.ContextProvenanceProbe
  type PAcc = PAllowed | PDenied
  rec PChk
    id: Int
    acc: PAcc
  rec PNode
    id: Int
    refs: List(Int)
  type PFound = PMissing | PFound(List(Int))

  @total true
  @reducible
  local fn pboth(a: Bool, b: Bool) -> Bool =
    match a
      True() -> b
      False() -> False()

  @total true
  @reducible
  local fn allowed_of(cs: List(PChk), id: Int) -> Bool =
    match cs
      [] -> False()
      [c | rest] -> pallowed_with(c, rest, id, c.id == id)

  @total true
  @reducible
  local fn pallowed_with(c: PChk, rest: List(PChk), id: Int, same: Bool) -> Bool =
    match same
      False() -> allowed_of(rest, id)
      True() ->
        match c.acc
          PAllowed() -> True()
          PDenied() -> False()

  @total true
  @reducible
  local fn find_refs(ns: List(PNode), id: Int) -> PFound =
    match ns
      [] -> PMissing()
      [n | rest] -> find_with(n, rest, id, n.id == id)

  @total true
  @reducible
  local fn find_with(n: PNode, rest: List(PNode), id: Int, same: Bool) -> PFound =
    match same
      False() -> find_refs(rest, id)
      True() -> PFound(n.refs)

  @total true
  @reducible
  local fn ok_id(fuel: List(Int), ns: List(PNode), cs: List(PChk), id: Int) -> Bool =
    match fuel
      [] -> False()
      [_ | f] -> pboth(allowed_of(cs, id), ok_found(f, ns, cs, find_refs(ns, id)))

  @total true
  @reducible
  local fn ok_found(fuel: List(Int), ns: List(PNode), cs: List(PChk), found: PFound) -> Bool =
    match found
      PMissing() -> False()
      PFound(refs) -> ok_ids(fuel, ns, cs, refs)

  @total true
  @reducible
  local fn ok_ids(fuel: List(Int), ns: List(PNode), cs: List(PChk), ids: List(Int)) -> Bool =
    match ids
      [] -> True()
      [i | rest] -> pboth(ok_id(fuel, ns, cs, i), ok_ids(fuel, ns, cs, rest))

  type PResult = PAccepted(List(Int)) | PRefused

  @total true
  @reducible
  local fn pick(fuel: List(Int), ns: List(PNode), cs: List(PChk), ids: List(Int)) -> List(Int) =
    match ids
      [] -> []
      [i | rest] -> pick_with(fuel, ns, cs, i, rest, ok_id(fuel, ns, cs, i))

  @total true
  @reducible
  local fn pick_with(fuel: List(Int), ns: List(PNode), cs: List(PChk), i: Int, rest: List(Int), ok: Bool) -> List(Int) =
    match ok
      False() -> pick(fuel, ns, cs, rest)
      True() -> [i | pick(fuel, ns, cs, rest)]

  @total true
  @reducible
  local fn pfinish_with(xs: List(Int), ok: Bool) -> PResult =
    match ok
      False() -> PRefused()
      True() -> PAccepted(xs)

  @total true
  @reducible
  fn pselect(fuel: List(Int), ns: List(PNode), cs: List(PChk), ids: List(Int)) -> PResult =
    pfinish_with(pick(fuel, ns, cs, ids), ok_ids(fuel, ns, cs, pick(fuel, ns, cs, ids)))

  @total true
  @reducible
  local fn prov_holds(r: PResult, fuel: List(Int), ns: List(PNode), cs: List(PChk)) -> Bool =
    match r
      PRefused() -> True()
      PAccepted(xs) -> ok_ids(fuel, ns, cs, xs)

  @total true
  local fn pfinish_prov(xs: List(Int), fuel: List(Int), ns: List(PNode), cs: List(PChk), ok: Bool, h: Equivalent(Bool, ok_ids(fuel, ns, cs, xs), ok)) -> Equivalent(Bool, prov_holds(pfinish_with(xs, ok), fuel, ns, cs), True()) =
    match ok
      False() -> reflexive(True())
      True() -> h

  @total true
  fn prov_law(fuel: List(Int), ns: List(PNode), cs: List(PChk), ids: List(Int)) -> Equivalent(Bool, prov_holds(pselect(fuel, ns, cs, ids), fuel, ns, cs), True()) =
    pfinish_prov(pick(fuel, ns, cs, ids), fuel, ns, cs, ok_ids(fuel, ns, cs, pick(fuel, ns, cs, ids)), reflexive(ok_ids(fuel, ns, cs, pick(fuel, ns, cs, ids))))
end
```

### provenance.exs

SHA-256: `ba0a0cef5cacfd3088902333f9381d4c14abbce878d1b121e39ee257ead79eb7`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
source = File.read!("/tmp/elz030-r2/provenance.cure")
{:ok, env} = Cure.Compiler.check_source(source)
IO.puts("PASS recursive prov_law: check_source")
audit = Cure.Audit.Ledger.audit_env(env)
for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total] do
  [] = Map.fetch!(audit, key)
end
0 = audit.absurd
IO.inspect(audit, label: "PASS clean audit", limit: :infinity)
{:ok, mod} = Cure.Compiler.compile_and_load(source)
IO.puts("PASS compile_and_load")
nodes = [{:PNode, 1, [2]}, {:PNode, 2, [3]}, {:PNode, 3, []}]
allowed = [{:PChk, 1, :PAllowed}, {:PChk, 2, :PAllowed}, {:PChk, 3, :PAllowed}]
fuel = List.duplicate(0, 16)
cases = [
  {"transitive allowed", nodes, allowed, fuel, {:PAccepted, [1]}},
  {"transitive denied", nodes, List.replace_at(allowed, 2, {:PChk, 3, :PDenied}), fuel, {:PAccepted, []}},
  {"missing source check", nodes, Enum.take(allowed, 2), fuel, {:PAccepted, []}},
  {"missing source node", Enum.take(nodes, 2), allowed, fuel, {:PAccepted, []}},
  {"cycle exhausts structural fuel", [{:PNode, 1, [2]}, {:PNode, 2, [1]}], allowed, fuel, {:PAccepted, []}},
  {"insufficient depth fuel", nodes, allowed, [0, 0], {:PAccepted, []}}
]
for {name, ns, cs, fs, expected} <- cases do
  actual = apply(mod, :pselect, [fs, ns, cs, [1]])
  if actual != expected, do: raise("#{name}: #{inspect(actual)}")
  IO.puts("PASS scenario: #{name}")
end
mutated = String.replace(source, "False() -> PRefused()", "False() -> PAccepted(xs)", global: false)
{:error, {:source_context, {:conversion_failure, _, _}, ctx}} = Cure.Compiler.check_source(mutated)
IO.puts("PASS guard-bypass negative: conversion_failure at #{inspect(ctx[:checking])}")
true = {:pfinish_with, 2} in mod.module_info(:exports)
IO.puts("PASS observed limit: local helper remains a BEAM export (not privacy)")
IO.puts("Result: 11 passed (3 compiler/audit, 6 finite scenarios, 1 proof negative, 1 export-limit observation)")
```
