# ELZ-030 — raw lookup correspondence blocker

Status: **production implementation incomplete; correspondence blocker in the
attempted String-keyed reorder strategy**. This does not invalidate the accepted
R1 ordered-suffix lemma, and it is not a claim that every possible implementation
is infeasible. No ready Piece, production source, manifest or acceptance evidence
is published by this report.

## Exact missing connection

The accepted plan evaluates a memoized list in dependency order, then must relate
its entries to the trusted raw graph, whose input order is unrestricted. R1
proved cache versus spec in the *same ordered suffix*. It did not prove that
String-keyed lookup preserves raw-node identity when that list is reordered.

The reduced obligation below isolates a swap of two unique nodes, both at version
1, with different permission verdicts. A query must find the same verdict before
and after a swap. It has the legitimate uniqueness premise
`same(a, b) = False`; it has no safety or cache-correctness premise. The proof
splits the two actual native lookup results. Three branches close; the fourth
has `same(a, q) = True` and `same(b, q) = True`. Closing it requires native
comparison congruence/transitivity (or reflection into String identity) to
contradict uniqueness. The attempted proof has no such lemma and fails there.
The intentionally failing `reflexive(True())` marks the exact unsolved branch;
it is not an accepted contradiction proof or an inserted axiom.

An unconstrained comparison assignment `ab=False, aq=True, bq=True` makes the
raw lookup return True and reordered lookup False. This is a countermodel to
reasoning from those Boolean answers alone, **not** a String runtime
counterexample. The finite native runtime corpus agrees on all 294 distinct-key
triples. The failure concerns the checked correspondence evidence, not observed
permission behavior or a broken native equality implementation.

Pinned source corroboration: `deps/cure/lib/cure/core/normalise.ex:418-435` states
that `struct_eq` folds int/float/atom literal operands and that ADT equality
never computes in the kernel. `deps/cure/lib/std/string.cure:74-76` uses native
`struct_eq` on character lists. `deps/cure/lib/std/equivalent.cure` distinguishes
Boolean comparison from propositional equality; its `sym`/`trans` combine
existing `Equivalent` proofs, not Boolean comparison answers. The separate
minimal `same(x, x) = True` attempt also remains neutral and fails conversion.
A search of the installed source found no native String equality reflection or
transitivity theorem suitable for this step. This is evidence about the current
pin and attempted strategy, not a proof of compiler-wide incompleteness.

## Why this is a stop, and possible next directions

The accepted M3/R1 rule requires reporting a correspondence gap. M7 applies only
to inability to check recursive **totality**, so it is not invoked. Neither a
conditional safe-cache law nor finite comparison tests replace this connection.
I have stopped before building a selector whose final proof depends on this
missing step. Full version/check/depth/reason and successful-selection laws are
still owed; this minimal reduction does not claim to exercise those fields.

Potential constructive routes for coordinator/reviewer consideration:

1. Preserve raw lookup order, resolve every reference once against that list,
   and use structural internal positions for dependency order and memo access.
   This could avoid requiring native equality algebra across reordered lookups.
   It needs a new checked representation/lookup connection, including missing
   references and cycles; it has **not** been implemented or proved here.
2. Find an existing checked native-equality bridge or develop the needed kernel/
   library support under separate toolchain ownership. No toolchain change is
   authorized or made here; PR #85 is an import-resolution fix and is not assumed
   to establish equality laws.

I request a proof-strategy decision/help, not permission to weaken the Contract.
The failed swap lemma is necessary for the attempted reorder-by-String lookup
strategy, **not established as necessary for every algorithm**. In particular,
this report must not be read as rejecting the first alternative without trying it.

## State, commands and results

Assigned worktree: `/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-030`.
Starting local/remote head: `50bcd281c82c3f4f8e7163cf77ebb4bab07eb000` (clean).
Normal merge of main `367c83bba62fc891caaa60d1536cdc39de3cebbb` produced
`4d8606db023c73d4db191c1658577968a1d6f793`. Protected-file changes in that
merge are upstream PR #83 only; no authored protected-file changes.
Last accepted green proof commit remains `50bcd28`; its probe reproduced on the
merged tree. Cure pin and installed checkout remain
`a004c335cc4e9f2203ba6f51fc31e8540b66378d`, Elixir 1.20.4 / OTP 29.1.2.
PR #85 was OPEN when checked this stage; its pin is not included.

All commands below run from that worktree with this prefix:

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
```

| Command after prefix | Exit | Observed result |
| --- | --- | --- |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-raw-link/check.exs /tmp/elz030-raw-link/reorder.cure` | 1 | `conversion_failure` in `swap_cases`: goal True = False, attempted True = True |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-raw-link/check.exs /tmp/elz030-raw-link/reflexivity.cure` | 1 | `conversion_failure`: native `same(x,x)` remains neutral |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-raw-link/runtime.exs` | 0 | Result: 4 passed; runtime fragment clean audit, compile, 294 swaps, neutral countermodel |
| `elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-r1/run.exs` | 0 | Result: 16 passed; prior R1 audit/scenarios/count/three negative controls remain green |

Logs: `/tmp/elz030-raw-link/{reorder,reflexivity,runtime,r1-regression}.log`.
The first scratch attempt with rewrites failed `rewrite_no_match`; factoring the
computed Boolean branch arguments exposed the actual remaining conversion goal.
That source-expression error is not the reported correspondence blocker.

No database, Mix setup/check, production test suite, export, registry integration
or ledger generation ran. The merge changed the compiler task but not installed
dependencies; these direct pure compiler calls use the named existing pin.
Full setup/check after pin and registry integration remain mandatory. No Contract,
labels, ready manifests, existing tests or original claim ownership changed.

## Reproduction

Extract the fenced source files below into `/tmp/elz030-raw-link`, verifying the
SHA-256 values, then run the commands above. The checker exits 1 for the two
failed theorem files by design; the runtime runner extracts only the executable
lookup fragment and must not be mistaken for a successful theorem check.
The original R1 source/runner are independently reproducible from
[its report](ELZ-030-correspondence-probe.md).

### reorder.cure

SHA-256: `d03081be9e38c3171fac8c5f6a6018693a740be20ce9f1e47cd5ce90e72ad64e`

```cure
# SPDX-License-Identifier: Apache-2.0
# Smallest raw-list -> reordered-cache lookup preservation obligation.
# All nodes use version 1; a and b are their String IDs.
# Distinct validated nodes can have different permission verdicts.
mod Elzoo.ContextSelectionRawLink
  @total true
  @reducible
  local fn same(left: a, right: a) -> Bool = Std.Builtin.struct_eq(a, left, right)

  @total true
  @reducible
  local fn raw_with(aq: Bool, bq: Bool) -> Bool =
    match aq
      True() -> True()
      False() ->
        match bq
          True() -> False()
          False() -> False()

  @total true
  @reducible
  local fn reordered_with(aq: Bool, bq: Bool) -> Bool =
    match bq
      True() -> False()
      False() ->
        match aq
          True() -> True()
          False() -> False()

  @total true
  @reducible
  fn raw_lookup(a: String, b: String, q: String) -> Bool =
    raw_with(same(a, q), same(b, q))

  @total true
  @reducible
  fn reordered_lookup(a: String, b: String, q: String) -> Bool =
    reordered_with(same(a, q), same(b, q))

  # Inspect the actual primitive answers; uniqueness is not a safety premise.
  @total true
  local fn swap_cases(a: String, b: String, q: String,
      distinct: Equivalent(Bool, same(a, b), False()),
      aq: Bool, bq: Bool,
      ha: Equivalent(Bool, same(a, q), aq),
      hb: Equivalent(Bool, same(b, q), bq)) -> Equivalent(Bool, raw_with(aq, bq), reordered_with(aq, bq)) =
    match aq
      False() ->
        match bq
          False() -> reflexive(False())
          True() -> reflexive(False())
      True() ->
        match bq
          False() -> reflexive(True())
          # Native equality transitivity would eliminate this branch using
          # distinct, ha and hb; they are Boolean equations, not String equality.
          True() -> reflexive(True())

  @total true
  fn lookup_swap(a: String, b: String, q: String,
      distinct: Equivalent(Bool, same(a, b), False())) -> Equivalent(Bool, raw_lookup(a, b, q), reordered_lookup(a, b, q)) =
    swap_cases(a, b, q, distinct, same(a, q), same(b, q), reflexive(same(a, q)), reflexive(same(b, q)))
end
```

### reflexivity.cure

SHA-256: `df4bf51de8bcd73e1098410371a3ad2fbe9a58a9cc9d2eadb46dcd9f29504fa2`

```cure
mod Elzoo.ContextSelectionNativeReflexivity
  @total true
  @reducible
  local fn same(left: a, right: a) -> Bool = Std.Builtin.struct_eq(a, left, right)
  @total true
  fn native_reflexivity(x: String) -> Equivalent(Bool, same(x, x), True()) =
    reflexive(True())
end
```

### check.exs

SHA-256: `8ec2811105da4b9791e8f8de720fcf01c9680bc09a6cf2574bf620f7ef0dec71`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
path = hd(System.argv())
case Cure.Compiler.check_source(File.read!(path)) do
  {:ok, env} ->
    IO.inspect(Cure.Audit.Ledger.audit_env(env), label: "audit", limit: :infinity)
    IO.puts("Result: checked")
  {:error, error} ->
    IO.inspect(error, label: "CHECK FAILED", limit: :infinity, pretty: true)
    System.halt(1)
end
```

### runtime.exs

SHA-256: `74b3885b04c38944c11a8a65cbff850966838d6c13e85cecd851fd86c25b24ce`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
source = File.read!("/tmp/elz030-raw-link/reorder.cure") |> String.split("  # Inspect the actual primitive answers") |> hd()
source = source <> "end\n"
{:ok, env} = Cure.Compiler.check_source(source)
audit = Cure.Audit.Ledger.audit_env(env)
for key <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total], do: [] = Map.fetch!(audit, key)
0 = audit.absurd
IO.inspect(audit, label: "PASS runtime fragment audit", limit: :infinity)
{:ok, mod} = Cure.Compiler.compile_and_load(source)
s = fn x -> {:String, String.to_charlist(x)} end
ids = ["a", "b", "q", "α", "é", "é", "a\0b"]
corpus = for a <- ids, b <- ids, a != b, q <- ids, do: {a, b, q}
for {a, b, q} <- corpus do
  args = [s.(a), s.(b), s.(q)]
  actual = apply(mod, :raw_lookup, args)
  ^actual = apply(mod, :reordered_lookup, args)
  expected = a == q
  ^expected = actual
end
IO.puts("PASS native runtime swap agreement: #{length(corpus)} distinct-key triples")
# Countermodel to inference from unconstrained Boolean comparison answers.
# Not a model of real String equality or a runtime counterexample.
answers = %{ab: false, aq: true, bq: true}
raw = if answers.aq, do: true, else: false
reordered = if answers.bq, do: false, else: answers.aq
false = answers.ab
true = raw
false = reordered
IO.puts("PASS neutral-comparison countermodel: ab=false, aq=true, bq=true; raw=true, reordered=false")
IO.puts("Result: 4 passed (runtime check/audit, compile, 294 finite swaps, neutral countermodel); raw-graph theorem NOT checked")
```

## Runtime log (not a theorem pass)

```text
PASS runtime fragment audit: %Cure.Audit.Ledger.Report{
  axioms: [],
  opaque: [],
  builtin_count: 22,
  holes: [],
  absurd: 0,
  not_proven_total: [],
  unresolved: [],
  unaudited: []
}
PASS native runtime swap agreement: 294 distinct-key triples
PASS neutral-comparison countermodel: ab=false, aq=true, bq=true; raw=true, reordered=false
Result: 4 passed (runtime check/audit, compile, 294 finite swaps, neutral countermodel); raw-graph theorem NOT checked
```
