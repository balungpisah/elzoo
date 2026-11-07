# ELZ-030 — Executed Cure feasibility probes

Proposal-stage evidence only. The full Contract is in [ELZ-030.md](ELZ-030.md).
The executable files ran from `/tmp/elz030-probes`; they are preserved below as
documentation, outside tracked implementation and outside the Piece compiler's
source roots. No new ready source, production test or proof is claimed.

## Environment and exact command

Working directory for every command:
`/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-030`.

Pinned dependency checked with `git -C deps/cure rev-parse HEAD`:
`a004c335cc4e9f2203ba6f51fc31e8540b66378d` (exit 0).
Elixir 1.20.4 / OTP 29.1.2; the dependency was built by this worktree's
`mix setup`, not borrowed from another checkout.

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' \
  elixir -pa '_build/test/lib/*/ebin' /tmp/elz030-probes/run.exs \
  > /tmp/elz030-probes/result.log 2>&1
```

Final exit **0**, 2026-11-08 approximately 04:02 WIB. The `Result` marker below
is emitted by this **probe runner**, not by `mix check` or ExUnit. The eight
runtime scenarios are finite tests; the two laws are quantified Cure terms.
The five negative controls fail proof conversion, not parsing. Access controls
remove the unrelated window laws first so the access proof must reject them.

The first assertion-runner attempt exited 1 because it matched only a top-level
`conversion_failure`, whereas the omit-reservations control correctly failed
with a `branch_type` wrapper around `conversion_failure`. The final runner
accepts exactly those two proof-failure shapes; it still rejects unexpected
parse/type/other failures. No law or probe decision was weakened to fix this.

The source blocks were extracted again, matched against their SHA-256 digests
and the executed scratch files, then rerun with output to
`/tmp/elz030-probes/reproduced.log`: exit 0, the same `Result: 17 passed`.

## Observed result

```text
PASS quantified window_law and access_law: check_source
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
PASS compile_and_load: Cure.Elzoo.ContextProbe
PASS runtime scenario: exact fit with reservation
PASS runtime scenario: revoked access excluded
PASS runtime scenario: stale access excluded
PASS runtime scenario: future access excluded
PASS runtime scenario: exact age boundary
PASS runtime scenario: greedy skip then fit
PASS runtime scenario: reservations alone exceed window
PASS runtime scenario: zero window and zero estimate
PASS negative control: bypass_window -> conversion_failure at :finish_window
PASS negative control: bypass_access -> conversion_failure at :finish_access
PASS negative control: omit_reservations -> conversion_failure at :finish_window
PASS negative control: omit_selected_estimates -> conversion_failure at :finish_window
PASS negative control: relax_final_age -> conversion_failure at "finish_access"
PASS expected limitation: native x <= x remains neutral (conversion_failure)
Result: 17 passed (3 compiler/audit checks, 8 finite runtime scenarios, 5 proof negative controls, 1 expected native limitation)
```

## What this establishes, and what remains

The checked `select` actually runs a greedy access/freshness filter and packing
pass, then recomputes the selected-list total and access predicate before it
can return `ProbeAccepted`. Its two public laws have no safety hypothesis.
Private inspect lemmas receive defining equalities constructed by reflexivity
inside those laws. All functions have checked totality; the clean audit has
no axioms, holes, unresolved, unaudited, opaque or unproved-total entries and
zero absurd terms.

Window evidence includes the selected list and reservations, not a disconnected
scalar balance. The access predicate includes allowed/denied, future checks
and age arithmetic. Native arithmetic is a trusted Cure/BEAM operation, not an
axiom supplied by this module. The independent window predicate catches removed
estimates/reservations; access mutations break the final guard's linkage to the
same access predicate at the original `now`/`age`.

This is a reduced executable feasibility kernel. It does **not** implement the
new schema, trusted-snapshot lookup, latest-version policy, source references,
recursive provenance, deduplication, sorting, drop explanations, estimator
translation or source export. Their implementation and final consumed-law
checks remain required. Proofs here are not claimed to cover a future file.
As with any specification, changing both a predicate and its guard can change
the property proved; independent scenario tests and exact-diff review remain
necessary. No successful-result law establishes progress or optimal packing.

The native limitation probe deliberately asks for `x <= x = True` by direct
reflexivity. Cure reports `conversion_failure` with neutral
`Std.Builtin#int_le` applied twice to the symbolic variable. It confirms the
ELZ-024 limitation; it does not show the guard-based successful-result laws
are impossible. Review D3 in the Contract before adopting their form.

## Reproduce from this document

After the pinned `mix setup`, extract the three exact code blocks below:

```python
from pathlib import Path
import re
text = Path("docs/work/ELZ-030-probes.md").read_text()
root = Path("/tmp/elz030-probes")
root.mkdir(parents=True, exist_ok=True)
for name in ["selection.cure", "native.cure", "run.exs"]:
    match = re.search(r"### " + re.escape(name) + r"\n\nSHA-256: `[^`]+`\n\n```[^\n]+\n(.*?)```", text, re.S)
    assert match, name
    (root / name).write_text(match.group(1))
```

Then run the exact command above. The runner saves detailed error contexts in
`/tmp/elz030-probes/*.error.txt`; they are diagnostics, not needed as source.

### selection.cure

SHA-256: `07c2d3345a87b5bfcb5409cdc196e0e5ab6644f3ccae448d4c110ef6879a8112`

```cure
# SPDX-License-Identifier: Apache-2.0
# Feasibility only: not the complete context-selection implementation.
mod Elzoo.ContextProbe
  type ProbeAccess = ProbeAllowed | ProbeDenied
  rec ProbeItem
    estimate: Int
    access: ProbeAccess
    checked_at: Int
  type ProbeResult = ProbeAccepted(List(ProbeItem)) | ProbeRefused

  @total true
  @reducible
  fn both(a: Bool, b: Bool) -> Bool =
    match a
      True() -> b
      False() -> False()

  @total true
  @reducible
  fn sum(xs: List(ProbeItem)) -> Int =
    match xs
      [] -> 0
      [x | rest] -> x.estimate + sum(rest)

  @total true
  @reducible
  fn fresh(x: ProbeItem, now: Int, age: Int) -> Bool =
    both(x.checked_at <= now, now - x.checked_at <= age)

  @total true
  @reducible
  fn permitted(x: ProbeItem, now: Int, age: Int) -> Bool =
    match x.access
      ProbeDenied() -> False()
      ProbeAllowed() -> fresh(x, now, age)

  @total true
  @reducible
  fn all_access(xs: List(ProbeItem), now: Int, age: Int) -> Bool =
    match xs
      [] -> True()
      [x | rest] -> both(permitted(x, now, age), all_access(rest, now, age))

  @total true
  @reducible
  fn fits(xs: List(ProbeItem), reserved: Int, window: Int) -> Bool =
    sum(xs) + reserved <= window

  @total true
  @reducible
  fn choose_with(x: ProbeItem, rest: List(ProbeItem), remaining: Int, now: Int, age: Int, ok: Bool) -> List(ProbeItem) =
    match ok
      False() -> choose(rest, remaining, now, age)
      True() -> [x | choose(rest, remaining - x.estimate, now, age)]

  @total true
  @reducible
  fn choose(xs: List(ProbeItem), remaining: Int, now: Int, age: Int) -> List(ProbeItem) =
    match xs
      [] -> []
      [x | rest] -> choose_with(x, rest, remaining, now, age, both(permitted(x, now, age), x.estimate <= remaining))

  @total true
  @reducible
  fn finish_with(xs: List(ProbeItem), window_ok: Bool, access_ok: Bool) -> ProbeResult =
    match window_ok
      False() -> ProbeRefused()
      True() ->
        match access_ok
          False() -> ProbeRefused()
          True() -> ProbeAccepted(xs)

  @total true
  @reducible
  fn finish(xs: List(ProbeItem), reserved: Int, window: Int, now: Int, age: Int) -> ProbeResult =
    finish_with(xs, fits(xs, reserved, window), all_access(xs, now, age))

  @total true
  @reducible
  fn select(xs: List(ProbeItem), reserved: Int, window: Int, now: Int, age: Int) -> ProbeResult =
    finish(choose(xs, window - reserved, now, age), reserved, window, now, age)

  @total true
  @reducible
  fn window_holds(r: ProbeResult, reserved: Int, window: Int) -> Bool =
    match r
      ProbeRefused() -> True()
      ProbeAccepted(xs) -> sum(xs) + reserved <= window

  @total true
  @reducible
  fn access_holds(r: ProbeResult, now: Int, age: Int) -> Bool =
    match r
      ProbeRefused() -> True()
      ProbeAccepted(xs) -> all_access(xs, now, age)

  @total true
  fn finish_window(xs: List(ProbeItem), reserved: Int, window: Int, w: Bool, a: Bool, h: Equivalent(Bool, fits(xs, reserved, window), w)) -> Equivalent(Bool, window_holds(finish_with(xs, w, a), reserved, window), True()) =
    match w
      False() -> reflexive(True())
      True() ->
        match a
          False() -> reflexive(True())
          True() -> h

  @total true
  fn finish_access(xs: List(ProbeItem), now: Int, age: Int, w: Bool, a: Bool, h: Equivalent(Bool, all_access(xs, now, age), a)) -> Equivalent(Bool, access_holds(finish_with(xs, w, a), now, age), True()) =
    match w
      False() -> reflexive(True())
      True() ->
        match a
          False() -> reflexive(True())
          True() -> h

  @total true
  fn window_law(xs: List(ProbeItem), reserved: Int, window: Int, now: Int, age: Int) -> Equivalent(Bool, window_holds(select(xs, reserved, window, now, age), reserved, window), True()) =
    finish_window(choose(xs, window - reserved, now, age), reserved, window, fits(choose(xs, window - reserved, now, age), reserved, window), all_access(choose(xs, window - reserved, now, age), now, age), reflexive(fits(choose(xs, window - reserved, now, age), reserved, window)))

  @total true
  fn access_law(xs: List(ProbeItem), reserved: Int, window: Int, now: Int, age: Int) -> Equivalent(Bool, access_holds(select(xs, reserved, window, now, age), now, age), True()) =
    finish_access(choose(xs, window - reserved, now, age), now, age, fits(choose(xs, window - reserved, now, age), reserved, window), all_access(choose(xs, window - reserved, now, age), now, age), reflexive(all_access(choose(xs, window - reserved, now, age), now, age)))
end
```

### native.cure

SHA-256: `71224b6e49df7cea2c46b95314575f7d975055ac558d6ae2b461fdf3dbb4b72e`

```cure
mod Elzoo.ContextNativeProbe
  @total true
  fn int_reflexive(x: Int) -> Equivalent(Bool, x <= x, True()) = reflexive(True())
end
```

### run.exs

SHA-256: `112173518412280b2fc0d3f80e6aeb9053a9f35134049dad8f5d19c98aead076`

```elixir
{:ok, _} = Application.ensure_all_started(:cure)
source = File.read!("/tmp/elz030-probes/selection.cure")
{:ok, env} = Cure.Compiler.check_source(source)
IO.puts("PASS quantified window_law and access_law: check_source")
report = Cure.Audit.Ledger.audit_env(env)
for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total] do
  [] = Map.fetch!(report, key)
end
0 = report.absurd
IO.inspect(report, label: "PASS clean audit", limit: :infinity)
{:ok, module} = Cure.Compiler.compile_and_load(source)
IO.puts("PASS compile_and_load: #{module}")

item = fn estimate, access, checked -> {:ProbeItem, estimate, access, checked} end
allowed = item.(5, :ProbeAllowed, 100)
denied = item.(2, :ProbeDenied, 100)
old = item.(2, :ProbeAllowed, 89)
future = item.(2, :ProbeAllowed, 101)
small = item.(2, :ProbeAllowed, 100)
large = item.(20, :ProbeAllowed, 100)
scenarios = [
  {"exact fit with reservation", [allowed], 3, 8, 100, 10, {:ProbeAccepted, [allowed]}},
  {"revoked access excluded", [denied, allowed], 0, 5, 100, 10, {:ProbeAccepted, [allowed]}},
  {"stale access excluded", [old, allowed], 0, 5, 100, 10, {:ProbeAccepted, [allowed]}},
  {"future access excluded", [future, allowed], 0, 5, 100, 10, {:ProbeAccepted, [allowed]}},
  {"exact age boundary", [allowed], 0, 5, 110, 10, {:ProbeAccepted, [allowed]}},
  {"greedy skip then fit", [large, small], 0, 5, 100, 10, {:ProbeAccepted, [small]}},
  {"reservations alone exceed window", [], 6, 5, 100, 10, :ProbeRefused},
  {"zero window and zero estimate", [item.(0, :ProbeAllowed, 100)], 0, 0, 100, 0,
    {:ProbeAccepted, [item.(0, :ProbeAllowed, 100)]}}
]
for {name, items, reserved, window, now, age, expected} <- scenarios do
  actual = apply(module, :select, [items, reserved, window, now, age])
  if actual != expected, do: raise("#{name}: #{inspect(actual)} != #{inspect(expected)}")
  true = apply(module, :window_holds, [actual, reserved, window])
  true = apply(module, :access_holds, [actual, now, age])
  IO.puts("PASS runtime scenario: #{name}")
end

mutations = [
  {"bypass_window", "False() -> ProbeRefused()", "False() -> ProbeAccepted(xs)"},
  {"bypass_access", "          False() -> ProbeRefused()", "          False() -> ProbeAccepted(xs)"},
  {"omit_reservations", "sum(xs) + reserved <= window", "sum(xs) <= window"},
  {"omit_selected_estimates", "sum(xs) + reserved <= window", "reserved <= window"},
  {"relax_final_age", "finish_with(xs, fits(xs, reserved, window), all_access(xs, now, age))",
    "finish_with(xs, fits(xs, reserved, window), all_access(xs, now, age + 1))"}
]
conversion_failure? = fn
  {:conversion_failure, _, _} -> true
  {:branch_type, _, {:conversion_failure, _, _}} -> true
  _ -> false
end
for {name, from, to} <- mutations do
  true = String.contains?(source, from)
  changed = String.replace(source, from, to, global: false)
  # Keep only the access law for access mutations: reject at its own proof.
  changed =
    if name in ["bypass_access", "relax_final_age"] do
      Regex.replace(~r/  @total true\n  fn (?:finish_window|window_law)\b.*?(?=\n  @total true|\nend)/s, changed, "")
    else
      changed
    end
  {:error, {:source_context, reason, info}} = Cure.Compiler.check_source(changed)
  true = conversion_failure?.(reason)
  File.write!("/tmp/elz030-probes/#{name}.error.txt", inspect(info, pretty: true, limit: :infinity))
  IO.puts("PASS negative control: #{name} -> conversion_failure at #{inspect(info[:checking])}")
end
native = File.read!("/tmp/elz030-probes/native.cure")
{:error, {:source_context, {:conversion_failure, _, _}, _}} = failure = Cure.Compiler.check_source(native)
File.write!("/tmp/elz030-probes/native.error.txt", inspect(failure, pretty: true, limit: :infinity))
IO.puts("PASS expected limitation: native x <= x remains neutral (conversion_failure)")
IO.puts("Result: 17 passed (3 compiler/audit checks, 8 finite runtime scenarios, 5 proof negative controls, 1 expected native limitation)")
```
