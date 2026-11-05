# Elzoo curated catalogue

This is a deliberately curated catalogue, not a port of Zoo's 402-row
inventory. An entry is a stable contract ID and a delivery plan. It may be
implemented by Elzoo, reused from OTP/a library, wrapped by a thin adapter, or
deferred until a working assembly needs it. The old Zoo names remain useful
research aliases, but aliases do not create duplicate implementation tasks.

The repository uses one Mix application to develop the catalogue. Consumers
take selected source bundles into their own applications. IDs are lowercase,
slash-separated and stable once used by an assembly. A rename requires an
explicit compatibility alias in the catalogue and a migration note.

## Functional coverage before implementation

Use the [capability model](capability-model.md) to choose a Piece boundary and
[coverage cases](capability-coverage.md) to test it against several products.
ELZ-014 adds 24 demand-led deferred handles where the previous inventory hid
identity, money, work/agent execution and artifact responsibilities inside broad
families. It adds no ready source or library dependency. Existing IDs remain
stable; family and provider-adapter entries do not license duplicate engines.

The inventory is now 89 IDs, of which 12 remain ready scoped bundles. The
`demand-led` phase has no promised place in the existing P0–P3 task chain;
select a real Assembly before opening implementation tasks. Candidate libraries
are documented in the [reference study](research/orchestration-references.md),
with adoption tests rather than assumed compatibility.

## Dispositions and grounding

| Disposition | Meaning | Who owns the risk |
| --- | --- | --- |
| **own** | New decision logic or an Elzoo contract. Cure is preferred for pure state transitions; Elixir owns the shell. | Elzoo: contract, invariants and evidence |
| **reuse** | Call a maintained OTP/platform API without copying it. | Upstream implementation; Elzoo still checks the API it relies on |
| **adapt** | Keep a small Elzoo adapter that validates, translates errors, adds correlation/redaction and runs integration checks around a reused dependency. | Split: upstream behavior plus Elzoo boundary |
| **defer** | A named capability is acknowledged but has no implementation phase. It must be pulled in by a concrete assembly and researched then. | No claim until a task adopts it |

Grounding labels use `P` (Cure proof), `T` (type/contract check), `X`
(executable check), `M` (monitor/telemetry), `U` (upstream contract), and `A`
(explicit assumption). “Proof” is one suitable form of evidence, not a
catalogue-wide badge requirement.

## Phase plan

Phases end at a working assembly, not at a row count:

| Phase | Working assembly | Scope that may be claimed at the exit |
| --- | --- | --- |
| P0 · bootstrap (partial) | `assembly/ingest-dedup-accumulate` | Pure Cure composition, a minimal typed port binding, a supervised volatile unit, fused/direct and OTP execution, Jason boundary. ELZ-002/003 finish the minimal named port/wiring checks; richer resilience wiring follows in P1. |
| P1 · message resilience | `assembly/request-route-retry` | Envelope IDs, request/reply, routing/transformation, idempotency, timeout/retry, error/dead-letter and bounded backpressure |
| P2 · durable workflow | `assembly/durable-job` | Event/input log, checkpoint/tail replay, schema upcast, transactional outbox, and one durable job/storage boundary |
| P3 · edge integration | `assembly/http-job` | One selected HTTP path, JSON/schema validation, SQL or job adapter, redacted telemetry and provider failure handling |
| P4 · scale/security/product | a product-specific assembly | OS-process or multi-host boundary, policy, tenancy, CRDT, AI, build/data and specialised adapters only as needed |
| later | none committed | Capabilities below that need a product, a security review or a missing upstream contract |

P0 and P1 are the only phases required to establish the composable runtime.
P2 is the first point at which the word durable is earned. P3 integrates the selected providers into a real effect/job Assembly. A narrow
Req client recipe is already exercised under ELZ-013; it does not complete
that Assembly. Documentation alone does not establish adoption.

## Implementations and readiness

[LEDGER.md](../LEDGER.md) is the generated, checked inventory of every stable
ID. It links usable source bundles and records the planned/deferred gaps.
`registry/catalogue.json` owns inventory/phase/disposition, per-piece
`piece.json` owns implementation/dependencies/grounding, and
`registry/providers.json` owns provider identities and checked baseline pins.
Do not maintain a second handwritten implementation-status table here.

Ready entries are scoped subsets. Direct library recipes can be useful now
without claiming an entire capability family or later Assembly is complete.
`integration/json` uses Jason directly; `integration/cure-json` is the optional
Cure string bridge. `integration/http` uses Req directly; Finch is transitive.
The hash recipe does not promise TLS or password handling. Registry and timers
are local OTP APIs, not distributed identity or durable scheduling.

Source bundles live under `pieces/<family>/<name>/`, containing `piece.json`,
README.md and whichever of `lib/`, `cure/`, `test/`, `examples/` they actually
need. Unimplemented capabilities have inventory entries, not empty code
folders or placeholder functions. See [consuming pieces](consuming.md) and
[ADR-0004](adr/0004-source-catalogue.md).

The independent [Gleam library evaluation](research/gleam-libraries.md) records
Lustre as an optional UI candidate. `ui/component` remains deferred; its
experiment is not a ready export or a dependency of operational contracts.

## Mapping the old Zoo families

The old catalogue is useful coverage evidence. This table accounts for every
old family without creating a task for every alias:

| Old Zoo family | Elzoo treatment | Curated destinations |
| --- | --- | --- |
| EIP messaging (construction, routing, transformation, endpoints, channels, system management) | Keep the message semantics and contracts; collapse names that are the same operation; use OTP for the shell | `core/envelope`, `delivery/*`, `runtime/*`, `state/outbox` |
| ReactiveX streams | Keep selected pure operators; treat subscriptions/scheduling/threading as wiring/runtime; defer the long tail | `delivery/stream-combinators`, `delivery/time`, `core/wiring` |
| Everyday system pieces | Keep value/contract concerns needed by a product; adapt providers; defer domain breadth | `core/*`, `integration/*`, `assembly/*` |
| microservices.io | Keep database ownership, event sourcing, outbox, saga and contract-test ideas; no microservice deployment doctrine | `state/*`, `workflow/state-machine`, `core/wiring` |
| AI and agent harnesses | Keep as a future assembly and explicit untrusted-output boundary; no harness/tool registry in core | `integration/ai-model`, `assembly/agent-product` |
| primitives/protocols | Own small pure decisions; adapt codecs/security/protocol providers; defer broad parser/data libraries | `core/*`, `integration/json`, `integration/http`, `integration/crypto` |
| foreign units/adapters | Keep the adapter contract; select a maintained library per real need | `runtime/adapter`, `integration/*`, `runtime/os-isolation` |
| distributed systems | Keep idempotency, ordering, retry and durable delivery contracts; defer consensus/replication until a product needs them | `delivery/*`, `state/*`, `state/replication` |
| CRDTs | Preserve as a named future family, not a bootstrap requirement | `state/crdt` |
| Release It! stability | Keep timeout, circuit-breaker, bulkhead, load-shed and backpressure as policies; reuse OTP for restart | `delivery/retry-timeout`, `delivery/circuit-breaker`, `delivery/backpressure`, `runtime/supervision` |
| state machines/build systems | Keep state machines for workflows; defer build-system scheduling to a product | `workflow/state-machine`, `workflow/build-graph` |
| Erlang/OTP | Reuse maintained behaviours and primitives; do not rebuild GenServer, Supervisor, timers or registries | `runtime/*`, `delivery/time`, `runtime/registry` |

## Alias and drop ledger

Aliases are searchable vocabulary, not separate IDs. The following normalises
the largest old overlaps:

| Old names | One Elzoo ID | Why |
| --- | --- | --- |
| Message, Command Message, Document Message, Event Message, Format Indicator | `core/envelope` | Same envelope schema with a `kind`/version field |
| Request-Reply, Remote Procedure Invocation, Return Address, Correlation Identifier | `delivery/request-reply` + `core/envelope` | One caller state machine and envelope metadata |
| Idempotent Receiver, Idempotent Consumer | `delivery/idempotency` | Same duplicate-suppression contract |
| Message Router, Content-Based Router, Filter, Recipient List, Splitter, Expiration | `delivery/routing` | One family with distinct functions and laws |
| Translator, Mapper, Content Filter, Anti-corruption Layer | `delivery/transformation` | Pure shape conversion and explicit merge |
| Message Store, Write-Ahead Log, Event Sourcing, Session Log | `state/event-log` | Same append/replay contract; domain meaning remains in the event type |
| Transactional Client, Transactional Outbox, Guaranteed Delivery | `state/outbox` plus `delivery/dead-letter` | Commit/ack and quarantine are separate concerns |
| Singular Update Queue, Event-driven Consumer, Serialize | `runtime/unit` | OTP mailbox/state serialization is the shell |
| Supervisor, Let It Crash, Supervision Tree | `runtime/supervision` | OTP owns lifecycle; Elzoo declares policy |
| Timer, Interval, Delay, Debounce, Timeout | `delivery/time` + `delivery/retry-timeout` | Clock is an input; timeout policy is separate |
| Circuit Breaker, Retry with Backoff, Catch | `delivery/circuit-breaker` + `delivery/retry-timeout` | Failure-policy family split between breaker state and retry/deadline policy |
| Scatter-Gather, API Composition | `delivery/aggregation` | Correlated fan-out/fan-in |
| Saga, Process Manager | `workflow/state-machine` | Stateful compensation and ordering |
| Event Bus, Messaging, Decoupling Middleware, Pipes-and-Filters | `core/wiring` | Wiring declares the topology; no second bus abstraction |

Dropped or explicitly out of scope from the old inventory:

* Architecture/team/deployment/UI styles (monolith, microservice, service per
  team/VM/container, serverless, page composition) are product/deployment
  choices, not catalogue pieces.
* Zoo's custom CLI, generated catalogue index, badge system and elaborate gate
  loop are not carried into Elzoo bootstrap. GitHub issues, Mix and this
  catalogue are enough until a real search problem appears.
* An exhaustive Rx operator list, every CRDT sequence variant, every foreign
  protocol/vendor, full AI harness, consensus alternative, and build-system
  rebuilder are deferred rather than promised.
* “Exactly once”, whole-repository lowest assurance, mandatory proof of every
  operation, and a single central engine are not Elzoo claims.

## Sources and review rule

Names and capability coverage were compared with the old Zoo documents and
their source catalogues. Current dependency candidates and authoritative API
links are in [`dependencies.md`](dependencies.md). A candidate becomes
`reuse` or `adapt` only after its exact version is locked and a runtime task
exercises the API and failure behavior; a link or a successful local
documentation fetch is not adoption evidence.

The architecture gate checks that this catalogue remains a plan for working
assemblies. It must not grow by copying rows from old Zoo without a product
boundary, owner, disposition and phase.
