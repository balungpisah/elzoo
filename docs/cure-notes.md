# Cure notes for Elzoo

This is a short implementation guide for the pinned Cure release, not a
replacement for Cure's documentation. Facts marked “observed” come from the
earlier spike and the production-shaped files in this repository. A fact about
the language/compiler is not automatically a claim about an Elzoo assembly.

## Pin and source

Use the exact Cure commit
[`a004c335cc4e9f2203ba6f51fc31e8540b66378d`](https://github.com/cure-lang/cure-lang/commit/a004c335cc4e9f2203ba6f51fc31e8540b66378d)
from `mix.exs`. The upstream repository has both a branch and a tag named
`v0.35.0`; a bare branch/tag selection is not reproducible. The target
toolchain is Elixir 1.20.4 / OTP 29.1.2.

The pinned Cure README describes dependent types, records, effects, typed
actors/supervisors and compilation to BEAM. The Elzoo bootstrap deliberately
uses plain Cure functions plus Elixir OTP shells. Cure actor/supervisor macros
are a candidate for a later comparison, not an adopted runtime surface.

## Observed facts and safe patterns

### Generic composition works

The production exemplar in [`pieces/assembly/ingest-dedup-accumulate/cure/elzoo/core.cure`](../pieces/assembly/ingest-dedup-accumulate/cure/elzoo/core.cure) uses:

```text
Transition(state, Option(output))
```

and a generic `compose` function. A `None()` output leaves the downstream
state alone; a `Some(value)` calls the next operator. The runtime test checks
the actual compiled modules, nested composition and an independently compiled
consumer. The same pure function is called directly and through the Elixir
`GenServer` shell.

This is a zero-or-one output contract, not a general fan-out theorem. Keep
fan-out as a later, explicitly typed operator/assembly. Do not infer that the
old Zoo's full routing, bounded receiver or durable hop already exists.

### Record ABI must be measured

The spike initially followed a prose example that described record maps. The
measured release boundary in the executed harness was tagged tuples:

```elixir
{:Transition, state, output}
{:Joined, left, right}
{:Message, sender, incarnation, sequence, value}
```

The Elixir wrapper in [`pieces/assembly/ingest-dedup-accumulate/lib/elzoo/runtime.ex`](../pieces/assembly/ingest-dedup-accumulate/lib/elzoo/runtime.ex) keeps
that ABI in one small set of projections (`transition/1`, `joined/1` and
`message_fields/1`). The wrapper is intentionally not spread through business
code. If a Cure upgrade changes the emitted ABI, compile a probe and update
only the boundary after reviewing the changed evidence; do not rely on README
examples over the observed compiler.

### Type/proof authoring traps

The following were observed against the pinned release:

* `reflexive(None())` left the element type underconstrained. A typed context,
  such as `reflexive(emit(True(), input))`, compiled.
* `True()` and `False()` were accepted in the equality indices where lowercase
  boolean literals caused conversion failure.
* Record projections in dependent type indices needed named selector
  functions.
* Keep a return type on the same line as `->`; a line break immediately after
  the arrow caused a parse/elaboration failure in the spike.
* Explicit `@total true` on the proof-facing `emit` function made the intended
  totality requirement clear.
* A separately compiled module imports the existing Cure module through its
  source root; the consumer must not duplicate operator bodies.

These are authoring constraints, not reasons to weaken a contract. Keep the
smallest explicit annotation that disambiguates the intended type and add a
negative compile test when an interface is important.

### Foreign calls are assumptions

[`pieces/integration/cure-json/cure/elzoo/adapter.cure`](../pieces/integration/cure-json/cure/elzoo/adapter.cure) declares
`@extern(Elixir.Jason, :encode!, 1)`. The runtime test confirms the call,
round-trips selected strings through Jason and checks explicit invalid-input
and failing-library results in [`pieces/integration/cure-json/lib/elzoo/json_boundary.ex`](../pieces/integration/cure-json/lib/elzoo/json_boundary.ex).
The Cure audit sees Jason as a foreign axiom. That is the correct result: it
separates the pure Cure evidence from the upstream implementation instead of
claiming to prove Jason.

Keep `@extern` declarations in a narrow adapter module. Validate inputs and
translate exceptions at the Elixir boundary. Never let an external return
value silently become a pure theorem.

### OTP placement has a concrete limit

`Elzoo.Unit` stores a Cure operator/state pair in a `GenServer`; `Supervisor`
restarts it. A restart resets the volatile state, so a previously delivered
deduplication key can be accepted again. The production test records this
explicitly. It is not evidence of durable delivery, replay, crash atomicity,
network ordering or exactly-once behavior.

The bootstrap's “hop” is a synchronous `GenServer.call` boundary used to
exercise the shell. A future asynchronous hop needs a message envelope,
ack/retry point, idempotency scope and a stated durability mode. Do not call a
mailbox a WAL.

## Present versus target

| Area | Present in this repository | Target / open work |
| --- | --- | --- |
| Pure decisions | Generic Cure operators and nested assembly | More operators only when a working assembly needs them |
| Ports | Cure function signatures plus core/port exact schema/version/direction checks | Delivery and wiring validation (ELZ-003); runtime payload validation (ELZ-004) |
| Edges | Direct call and synchronous GenServer-boundary comparison | Async hop with explicit volatile/at-least-once classes |
| State | Volatile operator state plus test snapshot | Event log/checkpoint/upcast/outbox with crash tests |
| OTP | Elixir GenServer and Supervisor shell | Application, DynamicSupervisor, Registry only where needed; compare Cure actor/sup macros later |
| Effects | Jason adapter with explicit error translation | HTTP/SQL/job adapters selected and tested one at a time |
| Assurance | Selected Cure proofs, compile negatives, ExUnit/model checks and upstream Jason contract | Claim-level evidence per assembly; no proof-everything mandate |

## Historical evidence and limits

The research spike that established these observations is [Zoo commit
`ffd64a4`](https://github.com/sabrang-mdp/zoo/commit/ffd64a4). It is historical
evidence, not a dependency or a gate for this repository. The production files
and test listed above are the self-contained bootstrap evidence.

The spike did not settle the complete Zoo receiver contract, bounded windows,
fan-out, envelope encoding, async distributed hops, WAL/replay, outbox
atomicity, native/OS isolation, compiler soundness or total cost. Preserve
those limits when describing Cure adoption.

## Upgrade checklist

Before changing the Cure pin:

1. compile the production `cure/*.cure` files through the new compiler;
2. run the direct, OTP-boundary and nested assembly tests;
3. run the false-proof, incompatible-port and unfinished-proof negatives;
4. rerun the Cure audit and inspect foreign assumptions; and
5. probe record ABI and update the single Elixir projection boundary if it
   changed.

Do not resolve an upgrade failure by deleting a negative control or weakening
a law. Record a language/compiler lesson here and file a workflow task when a
design or tool change is needed.

### Mix source roots and compiler integration

For the pinned release, pass only the project Cure source directory as
`source_roots`. The compiler resolves its own standard library. Adding every
`Cure.Stdlib.Paths.all_source_dirs()` directory made a separately imported
consumer spend minutes compiling in the bootstrap probes. With only the
project root, the same core and consumer compiled in approximately 2.6 and
0.35 seconds on the bootstrap machine. Do not preload the whole standard
library as a workaround: its default source JIT can compile unrelated modules.

The Mix compiler publishes actual BEAM files before the application manifest
is generated. A successful type/check command alone is insufficient: compile
negative controls include a false law, incompatible types and an unfinished
proof. Keep the real compiler path and those controls in `mix check`.

### Cache relocation and split imports

Cure's generated standard-library artifacts retain source identities. Copying
those generated caches to another checkout caused `duplicate_module_identity`
for Std.Option with the old and new absolute paths. No result from that failed
build was accepted. Rebuilding the generated dependency artifacts in place
resolved it. Do not copy Cure artifact generations between checkout paths.
The consumer regression reuses only upstream code paths and explicitly checks
that no Elzoo runtime modules are loaded before compiling copied source.

## Higher-order function boundary

Cure higher-order arguments use curried BEAM functions. Passing an Elixir
`fn state, input -> ... end` to compose raises BadArityError; use
`fn state -> fn input -> ... end end`. The composition bundle tests exercise
this boundary. Exported MFA calls still use the exported arity. Auditing
modules with cross-bundle imports requires `Compiler.check_source/2` with
source_roots followed by `Audit.Ledger.audit_env/1`; audit_source/2 does not
accept project source roots.

For an imported nullary type across source roots, use the qualified spelling
`Elzoo.Idempotency.Message`. Bare `Message` compiled but produced W001
uppercase-variable migration warnings in the multi-root catalogue; qualifying
the type removes them and retains the incompatible-connection negative test.

## Nominal String at a descriptor boundary (ELZ-002)

Pinned Cure `String` literals erase to `{:String, unicode_codepoint_list}`,
not an Elixir binary. `Elzoo.Port.decode/1` validates UTF-8 binaries and
translates them explicitly; `encode/1` reverses that representation. The
Port test compares an actual compiled Cure descriptor with the translated
map, including non-ASCII text. Do not infer runtime ABI from a foreign
`@extern` signature that passes values through without inspecting them.

The initial descriptor probe using `==` on String emitted a call to
`Cure.Std.String.__impl_Equatable_Std.String#String_==/2`, absent in the
compiler-free consumer runtime. No passing evidence was accepted from that
probe. Exact descriptor identity uses the upstream kernel
`Std.Builtin.struct_eq` through a local generic helper; it needs no String
protocol module at runtime. The explicit type operand must resolve as a type:
bare `String` in expression position resolved to the record constructor in
this probe, while the generic type parameter worked. Both new bundle audits
and the independent consumer test exercise this path. This is exact nominal
text equality, not normalization or schema subtyping.
