# Elzoo architecture

Status: source catalogue architecture; ADR-0004 defines distribution. This document is the
contract for the pieces that will be implemented; it is not a claim that all
of the target runtime already exists.

Elzoo keeps Zoo's useful seam—pure decisions composed behind ports—but makes
the seam fit Cure and OTP. Cure owns new pure decisions where a small law is
valuable. Elixir/OTP and a maintained library own the runtime and integration
implementation that already exists. The Elzoo boundary owns the message
contract, error translation, lifecycle policy, and evidence for the claims it
makes about using those dependencies.

## Functional scope

The [capability model](capability-model.md) defines how to split reusable
responsibilities and preserve their invariants across products. The
[coverage cases](capability-coverage.md) stress those contracts with SaaS,
identity, money, task management and agent orchestration workflows. These cases
identify missing responsibilities without claiming implementation or extending
all of them into the execution kernel. Work Item, Run and Attempt keep business
intent separate from execution. Existing ready subsets keep their present claims.

## Application foundation direction

Applicable runtime operational interfaces follow
[Telemetry, Config and Control](operational-contracts.md). Their declaration is
independent of language and UI choices. Pure Pieces do not acquire side effects
or a management endpoint merely by appearing in the catalogue.

Ash is the preferred candidate for declared application actions, authorization
and resource lifecycle; see [ADR-0005](adr/0005-ash-foundation-and-upstream-first.md).
ELZ-015 is an isolated proof-of-fit, not production adoption. AshPostgres and
AshOban must pass the selected durability/transaction tests before use. Pure
Cure Pieces remain independently consumable. Ash Resources do not replace the
Operator/Port contract, and no global Ash application is required by the
catalogue. Existing ready claims remain unchanged.

The [Gleam evaluation](research/gleam-libraries.md) separately explores optional
embeddable UI. It does not change these runtime contracts or require a frontend
language for backend Pieces.

## Delivery and source ownership

The root Mix application is a development harness. Developers take selected
source bundles into their own Mix project, with no required Elzoo runtime
application or supervision tree. `pieces/<family>/<name>/` colocates the
source, contract, tests/examples and claim metadata. Library recipes use
upstream APIs directly; an Adapter exists only for an actual translation.

The checked [piece ledger](../LEDGER.md) distinguishes implementations from
planned capabilities and records individual claims. A source copy carries
Apache-2.0 license/notice and a provenance receipt. It does not carry a proof
of subsequent edits or arbitrary compositions. See [consuming](consuming.md)
and [ADR-0004](adr/0004-source-catalogue.md).

Generic composition lives in `pieces/core/operator`; exact-key idempotency
lives in `pieces/delivery/idempotency`. The OTP Unit depends only on the
transition tuple contract, not on a sample Runtime. The sample Assembly
combines these pieces. This preserves Zoo's recursive composition idea while
making its source delivery independent of a central host.

## Present versus target

The bootstrap is deliberately small and observable:

* One Mix application, pinned to Cure commit
  [`a004c335cc4e9f2203ba6f51fc31e8540b66378d`](https://github.com/cure-lang/cure-lang/commit/a004c335cc4e9f2203ba6f51fc31e8540b66378d),
  Elixir 1.20.4 and OTP 29.1.2.
* A Cure operator/assembly with a typed transition and zero-or-one output.
  The same decision code is called directly and from a supervised OTP unit.
* A small ingest → idempotency → accumulation assembly. It demonstrates
  composition and a process boundary; it is not a bounded receiver, a durable
  broker, or a complete port of the old Zoo receiver.
* Direct Jason and Req recipes, plus an optional Cure-to-Jason string bridge.
  OTP lifecycle/registry/timer/hash and Enum/Stream recipes call upstream APIs.
* Jason at one explicit Elixir boundary in the optional bridge. Jason's JSON implementation is an
  upstream contract, not a theorem about Elzoo.
* `mix setup` and `mix check` are the public commands. The executable checks
  in [`pieces/assembly/ingest-dedup-accumulate/test/elzoo/runtime_test.exs`](../pieces/assembly/ingest-dedup-accumulate/test/elzoo/runtime_test.exs) are the
  bootstrap evidence; this document does not turn every catalogue row into a
  proof obligation.

The target architecture adds durable delivery, adapters and assemblies in
small increments. A target row below is a design constraint, not present
behaviour. A claim is only present when its evidence is named in the claim
ledger and a gate or task has exercised it.

## Vocabulary and boundaries

The terms in `CONTEXT.md` are normative:

* An **operator** is a pure state transition. It cannot read a clock, send a
  process message, open a socket, or mutate a database.
* A **unit** owns one state machine behind named input and output ports. Its
  Elixir process is a lifecycle boundary, not the decision logic.
* A **port** has a direction, stable ID, schema/version, and delivery policy.
  A message is accepted only at a compatible port.
* An **edge** connects output to input. A fused edge is an in-process call in
  one transition; a hop is an asynchronous message crossing a unit boundary.
* **Wiring** declares units, ports and edges. An **assembly** is wiring plus
  units packaged behind its own ports, so another assembly can use it as one
  unit.
* An **effect** is a data request from a decision to the outside world. An
  **adapter** performs it and translates success, failure and timeout back to
  an ordinary result message.
* A **host** is the BEAM OS process containing supervised units. A BEAM
  process/GenServer is supervision and scheduling isolation; it is not a
  security boundary or an OS-process guarantee.
* **Grounding** names why a claim may be trusted: Cure's checked proof (`P`)
  or an explicit schema/type analysis (`T`), executable test (`X`), runtime
  monitor/telemetry (`M`), upstream contract (`U`), or an explicitly recorded
  assumption (`A`). An Elixir `@spec` by itself is documentation, not a
  checked guarantee. Several forms may be needed for one claim.

The boundary is intentionally asymmetric. Decisions may be reused at a
different placement because they do not know whether their caller is direct,
an OTP unit, or an assembly. Placement, effects, retries, persistence and
telemetry live in the Elixir shell and wiring.

## The composable core

### Operator contract

The first Cure ABI is the one measured by the Cure spike:

```text
Step(state, input) -> Transition(new_state, Option(output))
```

`None` means that no downstream operator is invoked. `Some(value)` invokes the
next compatible port. The generic composition operation pairs the two states,
feeds the second operator only on `Some`, and returns the second output. The
bootstrap intentionally has one output value at most; fan-out is represented
by a later routing operator or an assembly, not by an undocumented side
effect. A future multi-output contract must be a versioned port change with
its own tests.

For a stateful operator, the contract records:

```text
state schema + input port schema -> new state schema + output port schema
```

The state is serialisable at the unit boundary. A pure operator may be tested
or proved without knowing its eventual unit, and a unit may replace the
operator implementation while preserving its port contract.

Ordinary finite or lazy collection transformations may use Elixir's `Enum`
and `Stream` directly when their public contract is sufficient. Cure owns a
new operator only when a domain invariant, stateful policy or typed boundary
is missing; reimplementing a long ReactiveX tail solely to obtain more rows
would add risk without adding an assembly.

### Unit contract (target; bootstrap subset is explicit below)

A unit declaration consists of:

```text
unit id, version
  in  port id : message schema, delivery policy
  out port id : message schema, delivery policy
  state schema + durability mode
  needs: declared effect capabilities
  lifecycle: restart and shutdown policy
  evidence: claims and their grounding
```

The target unit shell performs only lifecycle work: receive a message, decode
and validate the envelope, call the pure step, persist/emit according to its
policy, and report telemetry. It does not decide business outcomes. On a
malformed message it emits an explicit error/dead-letter outcome rather than
calling a decision with an invalid value. The bootstrap subset currently has
the generic `GenServer` shell in [`pieces/runtime/unit/lib/elzoo/unit.ex`](../pieces/runtime/unit/lib/elzoo/unit.ex),
the Cure function signatures in [`pieces/assembly/ingest-dedup-accumulate/cure/elzoo/core.cure`](../pieces/assembly/ingest-dedup-accumulate/cure/elzoo/core.cure), and a
snapshot call; it does not yet have a general envelope decoder, persistence,
telemetry channel or dead-letter port.

### Ports, envelopes and schema versions

Port IDs are stable names such as `ingest.accepted` and `store.write`. They are
not Elixir module names and do not encode the current process location. A
port's schema has a version and a compatibility rule. The first runtime
version uses Cure's checked types at the pure boundary and Elixir validation at
the external boundary; generated manifests are a later tooling concern.

The logical envelope is:

```text
Envelope {
  message_id,             # unique delivery identity
  schema,                 # type name and version
  kind,                   # command, event, reply, error, control
  producer,               # unit/port identity
  correlation_id?,        # request/reply association
  causation_id?,          # message that caused this message
  idempotency_key?,       # receiver's duplicate scope
  sequence?,              # ordering within a producer stream
  deadline?,              # absolute expiry, if the port declares one
  trace?,                 # diagnostic context, never business payload
  payload
}
```

The envelope is a contract, not a promise that any transport supplies all
fields. An adapter must reject a missing field when the destination port
requires it. Business payload and telemetry are separate channels; sensitive
payload must never be copied into ordinary telemetry by default.

## Fused edges and hop edges

Fusing is a placement optimisation only when the operator satisfies the hop
contract. The observable semantics are intentionally different:

| Property | Fused edge | Hop edge |
| --- | --- | --- |
| Call | direct pure call | message across a unit boundary |
| Atomicity | one operator transition | sender and receiver commit separately |
| Interleaving | no message can intervene | other senders may interleave |
| Crash gap | shared fate | either side may fail between steps |
| Duplicate risk | none from the edge itself | redelivery can duplicate work |
| Ordering | the direct call's sequence | only the transport's stated order; never assume cross-sender order |
| Cost | no mailbox/codec | mailbox, validation and possibly persistence |

An ordinary OTP hop is a volatile, best-effort transport: a process mailbox is
not a write-ahead log, and a crashed process can lose unprocessed messages.
An application-level retry can deliver a message more than once. Therefore a
hop-facing receiver must be idempotent or declare a stronger delivery
contract. We make no exactly-once claim.

The bootstrap's `hopped/1` test uses synchronous `GenServer.call` request/reply
between two units so that the same decision code is exercised at a process
boundary without pretending that it is an asynchronous transport. The target
hop is asynchronous and has the following durable shape:

```text
caller --message--> receiver unit
  ^                    |
  +------reply---------+
```

```text
receive -> validate -> decide -> atomically commit state + outbox -> ack
                                             |
                                             +-- retry/send downstream
```

It provides at-least-once delivery when its adapter's storage and recovery
contracts hold. The receiver uses `message_id` or a declared idempotency key
to make redelivery harmless. If state and the outbox cannot be committed in
one transaction, the port must say so; a fused-equivalent claim is invalid.

## Volatile, durable and external state

State has an explicit mode on the unit, not an implication of using a
GenServer:

| Mode | Restart result | Delivery promise | Suitable for |
| --- | --- | --- | --- |
| `volatile` | state starts from its initial value; in-flight mailbox work may be lost | best effort; duplicates possible after caller retry | pure caches, transient aggregation, bootstrap assembly |
| `durable` | state recovers from a log/checkpoint and unapplied outbox | at-least-once when the storage/ack contract passes | durable workflows, receivers and jobs |
| `external` | state lives behind an adapter with the provider's transaction/consistency contract | inherited only to the named provider boundary | Postgres, object store, broker, vendor API |

Durable does not mean “the process never loses a message”. It means the unit
has a recovery protocol and a defined commit point. The target state pieces
are an append-only event/input log, checkpoint plus tail replay, schema
upcaster, and transactional outbox. Until those pieces exist, a unit marked
volatile must not advertise durable delivery. A database adapter may provide
durability for a domain record without making an Elzoo hop durable; both
contracts must be named.

## Effects and adapters

Pure Cure returns a decision and, where needed, an explicit effect request:

```text
Decision(state, input) -> {new_state, outputs, effects}
Effect -> Adapter -> Result | Error | Timeout
```

The optional Cure-to-Jason bridge uses a narrow Elixir shell that validates
input and maps exceptions to a declared error. General JSON uses Jason
directly; pure library calls do not need a wrapper merely to enter the ledger. The successful JSON bytes are checked against Jason's decoder
in the runtime test; Jason's implementation remains upstream-owned. The same
shape applies to HTTP, SQL, jobs and brokers.

Adapters must:

1. accept only a declared request schema;
2. translate all normal returns, exceptions and timeout/cancellation into a
   finite result type;
3. include enough correlation/causation metadata for the unit to match the
   result;
4. avoid logging secrets or full classified payloads;
5. carry the upstream version and link in the dependency record; and
6. ship an integration/conformance check at the boundary.

The adapter's library is not reimplemented in Cure. A Cure `@extern` call is
an explicit foreign assumption, never proof of the callee's implementation.
The candidate and adoption rules are in `docs/dependencies.md`.

## OTP lifecycle and isolation

The default host uses the maintained OTP behaviours:

* `Supervisor` owns unit children and restart strategy;
* `GenServer` is the ordinary unit shell and serialises a unit's state updates;
* `DynamicSupervisor` is for assemblies that create bounded, named units;
* `Registry` supplies local names only when a declaration needs them; names do
  not replace envelope identity;
* `Application` starts the host and its supervision tree; and
* `Task` is for bounded asynchronous adapter work, not an untracked business
  state machine.

The spike exercised a generic `GenServer` shell and `Supervisor` restart. It
also measured the important limit: restarting a volatile unit loses its
deduplication history, so a previously delivered key is accepted again. That
is expected behaviour and is why durable state is a separate mode.

OTP supervision is failure containment and restart, not a security sandbox.
An adapter that loads native code, handles hostile input, or needs independent
resource limits should run in an OS process/port or a separately supervised
service. We do not use a NIF or a BEAM process as a substitute for that
boundary without an explicit decision and integration test. Distribution and
node placement are later concerns; same-VM OTP tests do not prove network,
partition, or crash atomicity.

## Standard faces (lean target)

Zoo's seven faces remain useful concepts, but they are not seven mandatory
proofs or seven generated APIs in the bootstrap:

| Face | Bootstrap treatment | Target contract |
| --- | --- | --- |
| data ports | Cure function signatures in the exemplar; no general named/versioned port registry | typed/versioned input and output ports |
| errors | `Elzoo.JsonBoundary` returns explicit errors for its adapter only; no standard unit error/dead-letter port | standard error/dead-letter port |
| telemetry | no business telemetry channel; tests report ordinary ExUnit output | redacted metrics, traces and audit events |
| config | Mix/application config only | validated config port with runtime update policy |
| control | OTP start/stop/restart and synchronous `GenServer.call` tests | drain, pause, resume, upgrade commands |
| health | supervisor/process status only | readiness, degraded state and backlog/lag |
| state | in-memory state and test-only snapshot call | snapshot/restore/migrate plus replay |
| manifest | this documentation and source contracts | generated ports, needs and evidence manifest |

The target faces must not hide domain decisions in the host. A control command
can ask a unit to drain; it cannot silently invent a business transition.

## Working assemblies and phase gates

Progress is driven by a running assembly with a concrete boundary, not by
counting catalogue entries:

| Phase | Working assembly / exit evidence | New contract boundary |
| --- | --- | --- |
| 0 · bootstrap (partial) | `assembly/ingest-dedup-accumulate`: fused Cure run, supervised OTP run, independent model and Jason adapter checks | typed transition, unit shell, supervision and volatile process boundary; named port/wiring validation remains open in P0 (ELZ-002/003) |
| 1 · message resilience | `assembly/request-route-retry`: typed request/reply plus routing, timeout/retry, idempotency and bounded backpressure; negative contract tests | envelope IDs, hop delivery class, error/dead-letter port |
| 2 · durable workflow | `assembly/durable-job`: event/input log, checkpoint/tail replay, transactional outbox and a scheduled job; one storage adapter | durable state and at-least-once ack/retry |
| 3 · edge integration | `assembly/http-job`: one selected HTTP client/server path, JSON/schema boundary, telemetry and a database adapter | external effects, provider failure and redaction contracts |
| 4 · scale boundary | a measured multi-host or OS-process assembly, only if a product needs it | distribution/partition and isolation claims |
| later | policy, CRDT, AI, build/dataframe and specialised protocol assemblies | only as a concrete product requires them |

No later phase is implied by a row's existence. Each phase needs a small
assembly, its failure cases and its evidence record before the next family is
expanded.

## Claim and evidence ledger

The following claims are the ones the bootstrap may make now:

| Claim | Grounding | Evidence / limit |
| --- | --- | --- |
| Cure can express a generic typed zero/one-output composition | `P,T,X` | [`composition.cure`](../pieces/core/operator/cure/elzoo/composition.cure) and [`runtime_test.exs`](../pieces/assembly/ingest-dedup-accumulate/test/elzoo/runtime_test.exs) compile selected properties and typed-negative controls |
| The same pure transition can run directly and behind OTP | `X,U` | [`Elzoo.Runtime`](../pieces/assembly/ingest-dedup-accumulate/lib/elzoo/runtime.ex) and the runtime test compare fused/direct with synchronous GenServer-boundary traces; not arbitrary crash equivalence |
| OTP supervision restarts a unit | `X,U` | runtime test exercises `Supervisor` restart; volatile state is reset on restart |
| Jason can encode tested strings and errors are translated | `X,U,A` | [`pieces/integration/cure-json/lib/elzoo/json_boundary.ex`](../pieces/integration/cure-json/lib/elzoo/json_boundary.ex) and the bridge’s own tests; Jason implementation and Cure `@extern` signature remain foreign assumptions |
| volatile state may accept a redelivered key after restart | `X` | runtime test explicitly shows this; it is a limitation, not a bug |
| Cure's selected source has no unaudited holes or hidden axioms | `X` | owning-bundle tests audit all five pure Cure files; the cure-json test separately records the sixth file's explicit Jason extern assumption. This is not a compiler soundness audit |
| durable hop is at-least-once | `A` until Phase 2 | requires a real log/outbox/recovery test; no bootstrap claim |
| OTP process is an OS/security boundary | — | explicitly false; use an OS process or service for that requirement |
| all old Zoo catalogue rows are implemented | — | explicitly false; see curated dispositions and dropped aliases |

Each executable check links to the claim it supports in the table above. When
a dependency is upgraded, repeat the boundary check; a new version is not
adopted merely because its documentation exists. The historical spike that
motivated this design is [Zoo commit `ffd64a4`](https://github.com/sabrang-mdp/zoo/commit/ffd64a4),
not a dependency of this repository.

## Open design tasks

These are the workflow's existing task keys, not a second task system. Until
each issue closes, its row remains unresolved and is not an implementation
claim:

* `ELZ-003`: specify the canonical envelope encoding and schema-version
  compatibility rules for a hop.
* `ELZ-006`: define bounded-output and backpressure semantics beyond the
  bootstrap's zero/one output, including retry/dead-letter policy.
* `ELZ-007`: keep ordinary stream transformations on direct `Enum`/`Stream`
  reuse and make candidate/assembly selection deterministic.
* `ELZ-011`: integrate the adopted Req client recipe into the representative
  Effect/job boundary, including application-specific limits and failure
  translation. The narrow recipe does not complete that Assembly.
* `ELZ-009`: choose/evaluate the first durable log/outbox implementation and
  test crash/recovery ordering, including the ack commit point.
* `ELZ-010`: choose the scheduler/job provider and document transaction scope,
  idempotency and schema-upcast limits.

P4 OS-process isolation, telemetry redaction, and generated manifest are
deferred catalogue work. If a product pulls one forward, the workflow must
create an ELZ issue before implementation; this document intentionally does
not invent an untracked `ELZ-ARCH-*` backlog.

## Sources

* [Cure pinned source and README](https://github.com/cure-lang/cure-lang/tree/a004c335cc4e9f2203ba6f51fc31e8540b66378d)
* [Erlang/OTP design principles](https://www.erlang.org/doc/system/design_principles.html)
* [Elixir GenServer](https://hexdocs.pm/elixir/1.20.4/GenServer.html),
  [Supervisor](https://hexdocs.pm/elixir/1.20.4/Supervisor.html),
  [DynamicSupervisor](https://hexdocs.pm/elixir/1.20.4/DynamicSupervisor.html),
  [Registry](https://hexdocs.pm/elixir/1.20.4/Registry.html), and
  [Application](https://hexdocs.pm/elixir/1.20.4/Application.html)
* [Jason API](https://hexdocs.pm/jason/Jason.html)
* [Req API](https://hexdocs.pm/req/Req.html),
  [Finch API](https://hexdocs.pm/finch/Finch.html),
  [Ecto.Repo](https://hexdocs.pm/ecto/Ecto.Repo.html),
  [Postgrex](https://hexdocs.pm/postgrex/Postgrex.html), and
  [Oban](https://hexdocs.pm/oban/Oban.html) — candidates and limits are
  recorded in `docs/dependencies.md`.
* The earlier [Cure spike commit `ffd64a4`](https://github.com/sabrang-mdp/zoo/commit/ffd64a4)
  (historical research; the current repository's `pieces/` sources and tests are
  the self-contained bootstrap evidence).
