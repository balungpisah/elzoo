# ELZ-030 — raw-order positional correspondence probe

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

**Outcome: reduced positional feasibility passed; full production implementation
remains open.**

The pieces coordinator directed this bounded replacement probe in message
`msg_b6ffe37f761d`, continuing author task `task_825547efe488` /
`ctx_6171391913a6`. This is an internal representation choice within the accepted
Contract, not a Contract amendment, M7 fallback or permission to lower evidence.
The [raw String-key permutation attempt](ELZ-030-raw-lookup-blocker.md) is a
rejected strategy; the replacement performs no such permutation of raw lookups.

## Representation and checked claims

`PKey` carries native String ID and Int version. `PNode` carries that key, a typed
raw current check and its ordered reference keys. The reduced check contains
principal, tenant, allowed/denied Boolean and checked_at; `PContext` contains
principal, tenant, now, snapshot and max_age. These are raw operands, not supplied
correctness or safety flags. Hash/source binding, nil checks and the rest of the
production schema remain outside this reduced probe.

The canonical raw list never changes order. `resolve` performs deterministic
first-match scans with actual pinned native comparisons and returns `PMissing`
or `PFound(PHere | PThere(...))`. `index` interprets those structural positions.
`raw_lookup` independently scans the same raw list and returns the exact node
or `PAbsent`; it never calls resolve or index. The first no-hypothesis law is:

```text
forall raw: List(PNode), key: PKey:
  index(raw, resolve(raw, key)) = raw_lookup(raw, key)
```

`resolution_law` inducts on the actual raw list and shares only computed primitive
comparison answers with the spec, not an equality axiom. Its `shift_index` lemma
reduces structurally. It includes missing keys, versions, arbitrary raw order and
even duplicate raw keys under first-match semantics. That last quantification
is not a change to the facade Contract, which rejects duplicate provenance node
identities. No native comparison symmetry/transitivity/reflection is required.

`own_cache_raw_law` next relates positional lookup into the actual raw-order cache
of current-check verdicts to the independently written raw-check predicate.
Guard `own` and predicate `spec_own` independently list the raw principal/tenant,
permission and clock/freshness conditions and use separate conjunction folds.
Their connection is a structural Boolean-list lemma; neither assumes permission.
Native comparisons/arithmetic retain their pinned upstream meaning.

Finally, `prepare(raw, raw)` attaches resolved positions to **every ordered edge**,
including explicit missing resolutions, without dropping or reordering edges.
The reduced executable `run` builds that prepared graph once, tabulates bounded
layers into raw-order positional tables, resolves the query against the same raw
list, then returns its cached verdict. Independent `spec_key` recursively looks
up raw nodes and follows their raw reference keys with structural fuel. It calls
none of prepare, index, resolve, cache, levels, step or the guard predicates.
The third no-hypothesis law is:

```text
forall fuel: List(Bool), raw: List(PNode), key: PKey, context: PContext:
  run(fuel, raw, key, context) = spec_key(fuel, raw, key, context)
```

Fuel values are immaterial; list length bounds node depth. Leaf permission needs
one fuel cell. A root/branch/shared-leaf diamond needs three. Missing lookup or
exhausted depth returns False. Mutual structural lemmas connect each table
position, node and ordered edge fold to the raw recursive specification; the
checked totality audit covers those functions and lemmas. No caller-supplied
positions/cache or assumed-safe-cache premise enters any public probe theorem.
The spec is proof-side: only small tests execute it; no runtime production guard
may enumerate all paths on the large shared DAG.

## Deliberate reduced scope and production link

This is **layer tabulation**, not the final one-verdict-per-node scheduler. The
four-node diamond is stored `[root, right, leaf, left]`, deliberately not dependency
order. Runtime traces count four preparations and **twelve** node-layer evaluations
for three layers. A cache is built once per layer and reused across shared edges;
there is no path expansion in `run`. It would be false to report four final verdict
constructions or full task performance acceptance from this prototype.

The reusable connection demonstrated here is raw lookup → structural position →
raw-order cache slot → separately written raw graph permission. The production
algorithm must keep that canonical raw list and resolved positions, schedule
positions in dependency order, and construct each final node verdict once.
The layer-based raw spec supplies a concrete reference for the next correspondence
step; replacing layers with that schedule still needs a checked connection.
No unproved permutation of String-key searches is needed or authorized.

Still owed: full node/check/version/source/hash/tenant binding and schema validation;
missing-node versus unchecked/evaluated-cache-miss distinctions; bounded cycle
classification; first-failure reason and maximum successful-path-depth semantics;
one final verdict per node; 4096/4097 accounting; the full 16×16 fixture/time bound;
supersession, selection/dedupe/ranking/packing and returned-result laws; retrieval
veto/post-check; all production scenarios/mutations; facade and source export;
manifest/registry integration and full mix check. This probe's cycle example only
fails on fuel exhaustion; it does not claim the Contract's cycle classification or
failure precedence. Boolean correspondence cannot prove first-failure reasons.
All M1-M7 and R1-R8 production conditions remain binding.

The probe is typed internal Cure only, not a supported Piece API. Native record/
String/Int/list BEAM erasure and equality semantics remain upstream. The finite
String/binary comparison corpus is translation evidence, not an equality theorem.
No raw content, ambient clock, database or external Effect enters the probe.

## Executed evidence and toolchain transition

Working directory for every command:
`/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-030`.
Initial clean local/remote head was `1b66f92b26f0c221896c46f298300690b72410de`.
The first source checks used upstream Cure
`a004c335cc4e9f2203ba6f51fc31e8540b66378d`: resolution, own-cache and graph
laws checked with clean audit. The old-pin combined runtime/negative runner
was **not fully green**: scratch harness fixes were still being made (nullary
ADT tags are atoms, a proof error can be wrapped as `branch_type`, and a missing
query mutation needed a singleton leaf scenario because its diamond rewiring
introduced a masking cycle). No old-pin `Result: 32 passed` is claimed.

At the coordinator's update, the running probe was allowed to finish before
syncing. PR #85 is MERGED at `230cc5b211ef0599fe6a1980286c952111e5e0ae`
(`2026-11-07T22:06:55Z`). A normal merge into the task branch produced
`4017b167162e5acca42c89e5f19aee34acc169ca`. The fork and actual installed checkout
are `balungpisah/cure-lang` **`208248063d64e621782cd26dd30698ee42850a89`**.
Elixir 1.20.4 / OTP 29.1.2. All pin/provider/protected-file changes are inherited
from main; none was authored in this probe stage.

Exact refresh commands, both exit **0**:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' mix deps.get

env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:…@localhost/elzoo_pieces_test \
  mix setup
```

Logs: `/tmp/elz030-position/deps-get.log` and `setup.log`. Fresh setup compiled
Cure and 25 catalogue Cure sources; no `Result: N passed` summary is emitted by
these setup commands. No database was created or altered by this worker.
The supplied database URL was the required `elzoo_pieces_test` only.

Both relevant probe commands used the same locale/scheduler prefix above:

| Command after prefix | Exit | Result |
| --- | --- | --- |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-position/run.exs` | 0 | **32 passed**: 3 compiler/audit, 14 scenarios, 5 resolution/order/comparison/count groups, 5 proof negatives, 5 runnable scenario negatives |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-r1/run.exs` | 0 | **16 passed**: previous ordered-suffix R1 check/audit/scenarios/count and three proof negatives |

Logs: `/tmp/elz030-position/new-pin-result.log`, `new-pin-r1.log`.
The documented extraction/hash checks and a second positional execution also
passed (exit 0, **32 passed**), logged in `reproduced.log`.
These are scratch runner counts, not ExUnit or full `mix check` results.
The new proof audit has empty axioms, opaque, holes, unresolved, unaudited and
not_proven_total lists, absurd 0. The finite corpus includes denied/stale/tenant/
principal/future checks, exact age, shared sources, missing query/source, versions,
depth exhaustion and a cycle. It also exercises first-match duplicates as internal
lookup semantics, 24 raw-list permutations, 36 String/binary comparisons and
exact prepared-edge order. None replaces the production scenario gates.

Five mutants change runtime code only; all laws/specs stay unchanged:

| Mutation | Checked-law failure | Runnable scenario |
| --- | --- | --- |
| failed comparison resolves Here | `rewrite_no_match`, `resolve_hit_law` | missing query wrongly permits singleton leaf |
| cache Here slot always False | `branch_type`, `own_pos_law` | allowed diamond refused |
| discard prepared edges | `conversion_failure`, `join_law` | denied shared source wrongly permits root |
| skip raw current check | `conversion_failure`, `join_law` | denied shared source wrongly permits root |
| missing cache location permits | `conversion_failure`, `own_index_law` | missing query wrongly permits |

Detailed failures: `/tmp/elz030-position/<mutation>.error.txt`. Each runtime
mutation was additionally compiled without proof functions in a separate scratch
module; rejecting a malformed executable was not counted as proof evidence.
Source-expression iteration fixes were a `prepend` helper for list construction
inside theorem types and `node_refs` for record projection inside a theorem type;
these did not change the claimed law. No equality axiom or M7 fallback was used.

No full `mix check`, production scenario suite, export, registry/ledger integration
or PR ran in this bounded stage. The fork is now included and fresh setup is done;
full verification and any setup refresh after further changes remain required
before final review. Existing tests and ready Contracts are unchanged.

## Reproduction sources

From the assigned worktree, extract the fenced files below into
`/tmp/elz030-position`, verify their SHA-256 values, then run:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-position/run.exs
```

The runner checks/audits/compiles the source, executes the small raw-graph corpus,
and rejects five mutations against unchanged laws/specification. It additionally
compiles each mutant without proof functions in a separate scratch module and
requires a named scenario to disagree; syntax failure alone is insufficient.
All probe files are embedded here, not production catalogue sources.

```sh
python3 - <<'PYEXTRACT'
from pathlib import Path
import hashlib, re
text = Path("docs/work/ELZ-030-position-probe.md").read_text()
root = Path("/tmp/elz030-position")
root.mkdir(exist_ok=True)
for name in ["position.cure", "run.exs"]:
    match = re.search(r"### " + re.escape(name) + r"\n\nSHA-256: `([^`]+)`\n\n```[^\n]+\n(.*?)```", text, re.S)
    assert match and hashlib.sha256(match[2].encode()).hexdigest() == match[1]
    (root / name).write_text(match[2])
PYEXTRACT
```

### position.cure

SHA-256: `c61638220d32c41165515c7f332f951d7ca7e30044a95f4e178bc9648c784cc8`

```cure
# SPDX-License-Identifier: Apache-2.0
mod Elzoo.ContextSelectionPositionProbe
  type PPos = PHere | PThere(PPos)
  type PLocation = PMissing | PFound(PPos)
  rec PKey
    id: String
    version: Int
  rec PCheck
    principal: String
    tenant: String
    allowed: Bool
    checked_at: Int
  rec PNode
    key: PKey
    check: PCheck
    refs: List(PKey)
  rec PContext
    principal: String
    tenant: String
    now: Int
    snapshot: Int
    max_age: Int
  type PLookup = PAbsent | PPresent(PNode)

  @total true
  @reducible
  local fn same(a: t, b: t) -> Bool = Std.Builtin.struct_eq(t, a, b)
  @total true
  @reducible
  local fn key_eq(a: PKey, b: PKey) -> Bool =
    match same(a.id, b.id)
      False() -> False()
      True() -> same(a.version, b.version)

  @total true
  @reducible
  local fn shift(p: PLocation) -> PLocation =
    match p
      PMissing() -> PMissing()
      PFound(i) -> PFound(PThere(i))
  @total true
  @reducible
  fn resolve(raw: List(PNode), key: PKey) -> PLocation =
    match raw
      [] -> PMissing()
      [n | rest] -> resolve_hit(rest, key, key_eq(n.key, key))
  @total true
  @reducible
  local fn resolve_hit(rest: List(PNode), key: PKey, hit: Bool) -> PLocation =
    match hit
      True() -> PFound(PHere())
      False() -> shift(resolve(rest, key))

  @total true
  @reducible
  fn index(raw: List(PNode), location: PLocation) -> PLookup =
    match location
      PMissing() -> PAbsent()
      PFound(p) -> at(raw, p)
  @total true
  @reducible
  local fn at(raw: List(PNode), p: PPos) -> PLookup =
    match raw
      [] -> PAbsent()
      [n | rest] ->
        match p
          PHere() -> PPresent(n)
          PThere(tail) -> at(rest, tail)

  # Separate first-match lookup: no resolver, position or index call.
  @total true
  @reducible
  fn raw_lookup(raw: List(PNode), key: PKey) -> PLookup =
    match raw
      [] -> PAbsent()
      [n | rest] -> raw_hit(n, rest, key, key_eq(n.key, key))
  @total true
  @reducible
  local fn raw_hit(n: PNode, rest: List(PNode), key: PKey, hit: Bool) -> PLookup =
    match hit
      True() -> PPresent(n)
      False() -> raw_lookup(rest, key)

  @total true
  @reducible
  local fn prepend(n: PNode, rest: List(PNode)) -> List(PNode) = [n | rest]

  @total true
  local fn shift_index(n: PNode, rest: List(PNode), loc: PLocation) -> Equivalent(PLookup, index(prepend(n, rest), shift(loc)), index(rest, loc)) =
    match loc
      PMissing() -> reflexive(PAbsent())
      PFound(i) -> reflexive(at(rest, i))
  @total true
  local fn resolve_hit_law(n: PNode, rest: List(PNode), key: PKey, hit: Bool) -> Equivalent(PLookup, index(prepend(n, rest), resolve_hit(rest, key, hit)), raw_hit(n, rest, key, hit)) =
    match hit
      True() -> reflexive(PPresent(n))
      False() -> rewrite shift_index(n, rest, resolve(rest, key)) in resolution_law(rest, key)
  @total true
  fn resolution_law(raw: List(PNode), key: PKey) -> Equivalent(PLookup, index(raw, resolve(raw, key)), raw_lookup(raw, key)) =
    match raw
      [] -> reflexive(PAbsent())
      [n | rest] -> resolve_hit_law(n, rest, key, key_eq(n.key, key))

  @total true
  @reducible
  local fn g_all(tests: List(Bool)) -> Bool =
    match tests
      [] -> True()
      [h | t] ->
        match h
          False() -> False()
          True() -> g_all(t)
  @total true
  @reducible
  local fn s_all(tests: List(Bool)) -> Bool =
    match tests
      [] -> True()
      [h | t] ->
        match h
          True() -> s_all(t)
          False() -> False()
  @total true
  local fn all_law(tests: List(Bool)) -> Equivalent(Bool, g_all(tests), s_all(tests)) =
    match tests
      [] -> reflexive(True())
      [h | t] ->
        match h
          False() -> reflexive(False())
          True() -> all_law(t)

  @total true
  @reducible
  local fn own(n: PNode, c: PContext) -> Bool =
    g_all([n.check.allowed, same(n.check.principal, c.principal), same(n.check.tenant, c.tenant), n.check.checked_at <= c.snapshot, c.snapshot <= c.now, c.now - n.check.checked_at <= c.max_age])
  @total true
  @reducible
  local fn spec_own(n: PNode, c: PContext) -> Bool =
    s_all([n.check.allowed, same(n.check.principal, c.principal), same(n.check.tenant, c.tenant), n.check.checked_at <= c.snapshot, c.snapshot <= c.now, c.now - n.check.checked_at <= c.max_age])
  @total true
  local fn own_law(n: PNode, c: PContext) -> Equivalent(Bool, own(n, c), spec_own(n, c)) =
    all_law([n.check.allowed, same(n.check.principal, c.principal), same(n.check.tenant, c.tenant), n.check.checked_at <= c.snapshot, c.snapshot <= c.now, c.now - n.check.checked_at <= c.max_age])

  @total true
  @reducible
  fn own_cache(raw: List(PNode), c: PContext) -> List(Bool) =
    match raw
      [] -> []
      [n | rest] -> [own(n, c) | own_cache(rest, c)]
  @total true
  @reducible
  fn cache_at(cache: List(Bool), loc: PLocation) -> Bool =
    match loc
      PMissing() -> False()
      PFound(p) -> cache_pos(cache, p)
  @total true
  @reducible
  local fn cache_pos(cache: List(Bool), p: PPos) -> Bool =
    match cache
      [] -> False()
      [x | rest] ->
        match p
          PHere() -> x
          PThere(tail) -> cache_pos(rest, tail)
  @total true
  @reducible
  local fn spec_lookup_own(found: PLookup, c: PContext) -> Bool =
    match found
      PAbsent() -> False()
      PPresent(n) -> spec_own(n, c)
  @total true
  local fn own_pos_law(raw: List(PNode), c: PContext, p: PPos) -> Equivalent(Bool, cache_pos(own_cache(raw, c), p), spec_lookup_own(at(raw, p), c)) =
    match raw
      [] -> reflexive(False())
      [n | rest] ->
        match p
          PHere() -> own_law(n, c)
          PThere(tail) -> own_pos_law(rest, c, tail)
  @total true
  local fn own_index_law(raw: List(PNode), c: PContext, loc: PLocation) -> Equivalent(Bool, cache_at(own_cache(raw, c), loc), spec_lookup_own(index(raw, loc), c)) =
    match loc
      PMissing() -> reflexive(False())
      PFound(p) -> own_pos_law(raw, c, p)
  @total true
  fn own_cache_raw_law(raw: List(PNode), c: PContext, key: PKey) -> Equivalent(Bool, cache_at(own_cache(raw, c), resolve(raw, key)), spec_lookup_own(raw_lookup(raw, key), c)) =
    rewrite own_index_law(raw, c, resolve(raw, key)) in rewrite resolution_law(raw, key) in reflexive(spec_lookup_own(raw_lookup(raw, key), c))
  @total true
  @reducible
  local fn node_refs(n: PNode) -> List(PKey) = n.refs

  rec PResolved
    node: PNode
    edges: List(PLocation)

  @total true
  @reducible
  local fn edge_positions(raw: List(PNode), refs: List(PKey)) -> List(PLocation) =
    match refs
      [] -> []
      [key | rest] -> [resolve(raw, key) | edge_positions(raw, rest)]
  @total true
  @reducible
  local fn prepare_node(raw: List(PNode), n: PNode) -> PResolved =
    PResolved{node: n, edges: edge_positions(raw, node_refs(n))}
  @total true
  @reducible
  fn prepare(raw: List(PNode), todo: List(PNode)) -> List(PResolved) =
    match todo
      [] -> []
      [n | rest] -> [prepare_node(raw, n) | prepare(raw, rest)]

  @total true
  @reducible
  local fn g_join(a: Bool, b: Bool) -> Bool =
    match a
      False() -> False()
      True() -> b
  @total true
  @reducible
  local fn s_join(a: Bool, b: Bool) -> Bool =
    match a
      True() -> b
      False() -> False()
  @total true
  local fn join_law(a: Bool, b: Bool) -> Equivalent(Bool, g_join(a, b), s_join(a, b)) =
    match a
      True() -> reflexive(b)
      False() -> reflexive(False())

  @total true
  @reducible
  local fn cached_edges(prior: List(Bool), edges: List(PLocation)) -> Bool =
    match edges
      [] -> True()
      [loc | rest] -> g_join(cache_at(prior, loc), cached_edges(prior, rest))
  @total true
  @reducible
  local fn step_node(n: PResolved, prior: List(Bool), c: PContext) -> Bool =
    g_join(own(n.node, c), cached_edges(prior, n.edges))
  @total true
  @reducible
  local fn step(nodes: List(PResolved), prior: List(Bool), c: PContext) -> List(Bool) =
    match nodes
      [] -> []
      [n | rest] -> [step_node(n, prior, c) | step(rest, prior, c)]
  # Tabulate a bounded layer once for all nodes; no paths are enumerated.
  # This reduced evaluator is NOT the eventual one-verdict-per-node schedule.
  @total true
  @reducible
  local fn levels(fuel: List(Bool), nodes: List(PResolved), c: PContext) -> List(Bool) =
    match fuel
      [] -> []
      [_ | rest] -> step(nodes, levels(rest, nodes, c), c)
  @total true
  @reducible
  fn run(fuel: List(Bool), raw: List(PNode), key: PKey, c: PContext) -> Bool =
    cache_at(levels(fuel, prepare(raw, raw), c), resolve(raw, key))

  # Independent depth-bounded raw graph specification. No structural positions,
  # prepare, cache, levels, step, g_join or own calls. References retain order.
  @total true
  @reducible
  fn spec_key(fuel: List(Bool), raw: List(PNode), key: PKey, c: PContext) -> Bool =
    spec_found(fuel, raw, raw_lookup(raw, key), c)
  @total true
  @reducible
  local fn spec_found(fuel: List(Bool), raw: List(PNode), found: PLookup, c: PContext) -> Bool =
    match fuel
      [] -> False()
      [_ | rest] ->
        match found
          PAbsent() -> False()
          PPresent(n) -> s_join(spec_own(n, c), spec_edges(rest, raw, node_refs(n), c))
  @total true
  @reducible
  local fn spec_edges(fuel: List(Bool), raw: List(PNode), refs: List(PKey), c: PContext) -> Bool =
    match refs
      [] -> True()
      [key | rest] -> s_join(spec_key(fuel, raw, key, c), spec_edges(fuel, raw, rest, c))

  @total true
  local fn edges_law(fuel: List(Bool), raw: List(PNode), refs: List(PKey), c: PContext) -> Equivalent(Bool, cached_edges(levels(fuel, prepare(raw, raw), c), edge_positions(raw, refs)), spec_edges(fuel, raw, refs, c)) =
    match refs
      [] -> reflexive(True())
      [key | rest] -> rewrite run_law(fuel, raw, key, c) in rewrite edges_law(fuel, raw, rest, c) in join_law(spec_key(fuel, raw, key, c), spec_edges(fuel, raw, rest, c))

  @total true
  local fn step_node_law(fuel: List(Bool), raw: List(PNode), n: PNode, c: PContext) -> Equivalent(Bool, step_node(prepare_node(raw, n), levels(fuel, prepare(raw, raw), c), c), s_join(spec_own(n, c), spec_edges(fuel, raw, node_refs(n), c))) =
    rewrite own_law(n, c) in rewrite edges_law(fuel, raw, node_refs(n), c) in join_law(spec_own(n, c), spec_edges(fuel, raw, node_refs(n), c))

  @total true
  @reducible
  local fn more(fuel: List(Bool)) -> List(Bool) = [True() | fuel]
  @total true
  local fn step_pos_law(fuel: List(Bool), raw: List(PNode), todo: List(PNode), p: PPos, c: PContext) -> Equivalent(Bool, cache_pos(step(prepare(raw, todo), levels(fuel, prepare(raw, raw), c), c), p), spec_found(more(fuel), raw, at(todo, p), c)) =
    match todo
      [] -> reflexive(False())
      [n | rest] ->
        match p
          PHere() -> step_node_law(fuel, raw, n, c)
          PThere(tail) -> step_pos_law(fuel, raw, rest, tail, c)

  @total true
  local fn levels_pos_law(fuel: List(Bool), raw: List(PNode), p: PPos, c: PContext) -> Equivalent(Bool, cache_pos(levels(fuel, prepare(raw, raw), c), p), spec_found(fuel, raw, at(raw, p), c)) =
    match fuel
      [] -> reflexive(False())
      [_ | rest] -> step_pos_law(rest, raw, raw, p, c)
  @total true
  local fn missing_law(fuel: List(Bool), raw: List(PNode), c: PContext) -> Equivalent(Bool, False(), spec_found(fuel, raw, PAbsent(), c)) =
    match fuel
      [] -> reflexive(False())
      [_ | rest] -> reflexive(False())
  @total true
  local fn levels_index_law(fuel: List(Bool), raw: List(PNode), loc: PLocation, c: PContext) -> Equivalent(Bool, cache_at(levels(fuel, prepare(raw, raw), c), loc), spec_found(fuel, raw, index(raw, loc), c)) =
    match loc
      PMissing() -> missing_law(fuel, raw, c)
      PFound(p) -> levels_pos_law(fuel, raw, p, c)
  # No graph-order, safe-cache or result-safety hypotheses.
  @total true
  fn run_law(fuel: List(Bool), raw: List(PNode), key: PKey, c: PContext) -> Equivalent(Bool, run(fuel, raw, key, c), spec_key(fuel, raw, key, c)) =
    rewrite levels_index_law(fuel, raw, resolve(raw, key), c) in rewrite resolution_law(raw, key) in reflexive(spec_key(fuel, raw, key, c))
end
```

### run.exs

SHA-256: `47e37d9f53b62f017a69397b117eb8fb3c0a246449537b6196dc0345f3377845`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
source = File.read!("/tmp/elz030-position/position.cure")
{:ok, env} = Cure.Compiler.check_source(source)
IO.puts("PASS resolution_law, own_cache_raw_law, run_law: check_source")
audit = Cure.Audit.Ledger.audit_env(env)
for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total], do: [] = Map.fetch!(audit, key)
0 = audit.absurd
IO.inspect(audit, label: "PASS clean audit", limit: :infinity)
{:ok, mod} = Cure.Compiler.compile_and_load(source)
IO.puts("PASS compile_and_load")
s = fn x -> {:String, String.to_charlist(x)} end
key = fn id, version -> {:PKey, s.(id), version} end
check = fn allowed, tenant, principal, time -> {:PCheck, s.(principal), s.(tenant), allowed, time} end
node = fn id, version, ck, refs -> {:PNode, key.(id, version), ck, refs} end
ctx = {:PContext, s.("alice"), s.("tenant"), 100, 100, 10}
ok = check.(true, "tenant", "alice", 95)
root = node.("root", 1, ok, [key.("left", 1), key.("right", 1)])
right = node.("right", 1, ok, [key.("leaf", 1)])
leaf = node.("leaf", 1, ok, [])
left = node.("left", 1, ok, [key.("leaf", 1)])
raw = [root, right, leaf, left]
fuel = [true, true, true]
query = key.("root", 1)
change_check = fn raw, index, ck -> List.update_at(raw, index, &put_elem(&1, 2, ck)) end
cases = [
  {"shared diamond in nondependency raw order", raw, query, fuel, true},
  {"denied shared source", change_check.(raw, 2, check.(false, "tenant", "alice", 95)), query, fuel, false},
  {"stale shared source", change_check.(raw, 2, check.(true, "tenant", "alice", 89)), query, fuel, false},
  {"cross-tenant shared source", change_check.(raw, 2, check.(true, "other", "alice", 95)), query, fuel, false},
  {"current-principal mismatch", change_check.(raw, 2, check.(true, "tenant", "eve", 95)), query, fuel, false},
  {"future current check", change_check.(raw, 2, check.(true, "tenant", "alice", 101)), query, fuel, false},
  {"exact age boundary", change_check.(raw, 2, check.(true, "tenant", "alice", 90)), query, fuel, true},
  {"missing query", raw, key.("missing", 1), fuel, false},
  {"missing shared source", List.delete_at(raw, 2), query, fuel, false},
  {"wrong source version", List.replace_at(raw, 2, node.("leaf", 2, ok, [])), query, fuel, false},
  {"depth exhaustion", raw, query, [true, true], false},
  {"cycle exhausts structural depth", List.replace_at(raw, 2, node.("leaf", 1, ok, [query])), query, fuel, false},
  {"empty graph", [], query, fuel, false},
  {"zero fuel", raw, query, [], false}
]
for {name, graph, q, f, expected} <- cases do
  actual = apply(mod, :run, [f, graph, q, ctx])
  spec = apply(mod, :spec_key, [f, graph, q, ctx])
  if actual != expected or spec != expected, do: raise("#{name}: #{inspect({actual, spec, expected})}")
  loc = apply(mod, :resolve, [graph, q])
  indexed = apply(mod, :index, [graph, loc])
  ^indexed = apply(mod, :raw_lookup, [graph, q])
  IO.puts("PASS scenario: #{name}")
end
# Resolution is first-match for arbitrary well-typed raw lists; facade uniqueness
# validation remains a separate production precondition, not an assumed theorem.
duplicate = [node.("leaf", 1, check.(false, "tenant", "alice", 95), []), leaf]
{:PFound, :PHere} = apply(mod, :resolve, [duplicate, key.("leaf", 1)])
false = apply(mod, :run, [fuel, duplicate, key.("leaf", 1), ctx])
versioned = [node.("leaf", 2, ok, []), leaf]
{:PFound, {:PThere, :PHere}} = apply(mod, :resolve, [versioned, key.("leaf", 1)])
:PMissing = apply(mod, :resolve, [versioned, key.("leaf", 3)])
IO.puts("PASS first-match, version and missing resolution")
prepared = apply(mod, :prepare, [raw, raw])
[{:PResolved, ^root, root_edges} | _] = prepared
[{:PFound, {:PThere, {:PThere, {:PThere, :PHere}}}}, {:PFound, {:PThere, :PHere}}] = root_edges
IO.puts("PASS declared edge order retained in structural positions")
# Finite permutation check exercises native equality; no permutation theorem needed.
permutations = for a <- raw, b <- raw -- [a], c <- raw -- [a, b], d <- raw -- [a, b, c], do: [a,b,c,d]
24 = length(permutations)
for graph <- permutations, do: true = apply(mod, :run, [fuel, graph, query, ctx])
IO.puts("PASS 24 raw-list permutations (finite runtime evidence)")
ids = ["a", "b", "α", "é", "é", "a\0b"]
for a <- ids, b <- ids do
  actual = apply(mod, :same, [s.(a), s.(b)])
  if actual != (a === b), do: raise("String comparison disagreement")
end
IO.puts("PASS native String/binary agreement: 36 pairs")
# Run only the production-shaped probe entry while tracing. Preparation once;
# this layer prototype computes 4 nodes x 3 levels, NOT one final verdict/node.
for {fun, arity} <- [{:prepare_node, 2}, {:step_node, 3}], do: 1 = :erlang.trace_pattern({mod, fun, arity}, true, [:call_count])
{us, true} = :timer.tc(fn -> apply(mod, :run, [fuel, raw, query, ctx]) end)
{:call_count, 4} = :erlang.trace_info({mod, :prepare_node, 2}, :call_count)
{:call_count, 12} = :erlang.trace_info({mod, :step_node, 3}, :call_count)
for {fun, arity} <- [{:prepare_node, 2}, {:step_node, 3}], do: :erlang.trace_pattern({mod, fun, arity}, false, [:call_count])
IO.puts("PASS counted reduced schedule: 4 preparations, 12 node-layer evaluations, #{us} us; not production single evaluation")
mutations = [
  {"wrong_resolved_position", "False() -> shift(resolve(rest, key))", "False() -> PFound(PHere())"},
  {"wrong_cache_slot", "PHere() -> x", "PHere() -> False()"},
  {"drop_declared_edges", "edges: edge_positions(raw, node_refs(n))", "edges: []"},
  {"skip_current_check", "g_join(own(n.node, c), cached_edges(prior, n.edges))", "cached_edges(prior, n.edges)"},
  {"missing_cache_permits", "PMissing() -> False()", "PMissing() -> True()"}
]
for {{name, before, after_text}, i} <- Enum.with_index(mutations) do
  true = String.contains?(source, before)
  changed = String.replace(source, before, after_text, global: false)
  {:error, {:source_context, failure, details}} = Cure.Compiler.check_source(changed)
  kind = elem(failure, 0)
  true = kind in [:conversion_failure, :rewrite_no_match, :branch_type]
  File.write!("/tmp/elz030-position/#{name}.error.txt", inspect({failure, details}, pretty: true, limit: :infinity))
  IO.puts("PASS proof negative: #{name} -> #{kind} at #{inspect(details[:checking])}")
  # Check each mutant's actual behavior too. Remove proof functions only, then
  # compile under a separate scratch module; a rejected theorem alone does not
  # establish that a runnable mutation violates a positive/negative scenario.
  [header | blocks] = String.split(changed, "  @total true\n")
  runtime = header <> Enum.map_join(Enum.reject(blocks, &String.contains?(&1, "Equivalent(")), "", &("  @total true\n" <> &1)) <> "end\n"
  runtime = String.replace(runtime, "mod Elzoo.ContextSelectionPositionProbe", "mod Elzoo.ContextSelectionPositionNegative#{i}")
  {:ok, negative_mod} = Cure.Compiler.compile_and_load(runtime)
  {graph, q, expected} = case name do
    "wrong_resolved_position" -> {[leaf], key.("missing", 1), false}
    "wrong_cache_slot" -> {raw, query, true}
    "drop_declared_edges" -> {change_check.(raw, 2, check.(false, "tenant", "alice", 95)), query, false}
    "skip_current_check" -> {change_check.(raw, 2, check.(false, "tenant", "alice", 95)), query, false}
    "missing_cache_permits" -> {raw, key.("missing", 1), false}
  end
  actual = apply(negative_mod, :run, [fuel, graph, q, ctx])
  if actual == expected, do: raise("mutation did not fail scenario: #{name}")
  IO.puts("PASS scenario negative: #{name} got #{actual}, expected #{expected}")
end
IO.puts("Result: 32 passed (3 compiler/audit, 14 scenarios, 5 resolution/order/comparison/count groups, 5 proof negatives, 5 scenario negatives)")
```

## Executed new-pin log

```text
PASS resolution_law, own_cache_raw_law, run_law: check_source
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
PASS scenario: shared diamond in nondependency raw order
PASS scenario: denied shared source
PASS scenario: stale shared source
PASS scenario: cross-tenant shared source
PASS scenario: current-principal mismatch
PASS scenario: future current check
PASS scenario: exact age boundary
PASS scenario: missing query
PASS scenario: missing shared source
PASS scenario: wrong source version
PASS scenario: depth exhaustion
PASS scenario: cycle exhausts structural depth
PASS scenario: empty graph
PASS scenario: zero fuel
PASS first-match, version and missing resolution
PASS declared edge order retained in structural positions
PASS 24 raw-list permutations (finite runtime evidence)
PASS native String/binary agreement: 36 pairs
PASS counted reduced schedule: 4 preparations, 12 node-layer evaluations, 3 us; not production single evaluation
PASS proof negative: wrong_resolved_position -> rewrite_no_match at :resolve_hit_law
PASS scenario negative: wrong_resolved_position got true, expected false
PASS proof negative: wrong_cache_slot -> branch_type at :own_pos_law
PASS scenario negative: wrong_cache_slot got false, expected true
PASS proof negative: drop_declared_edges -> conversion_failure at "join_law"
PASS scenario negative: drop_declared_edges got true, expected false
PASS proof negative: skip_current_check -> conversion_failure at "join_law"
PASS scenario negative: skip_current_check got true, expected false
PASS proof negative: missing_cache_permits -> conversion_failure at :own_index_law
PASS scenario negative: missing_cache_permits got true, expected false
Result: 32 passed (3 compiler/audit, 14 scenarios, 5 resolution/order/comparison/count groups, 5 proof negatives, 5 scenario negatives)
```
