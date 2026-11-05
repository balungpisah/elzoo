# Elzoo curated catalogue

This is a deliberately curated catalogue, not a port of Zoo's 402-row
inventory. An entry is a stable contract ID and a delivery plan. It may be
implemented by Elzoo, reused from OTP/a library, wrapped by a thin adapter, or
deferred until a working assembly needs it. The old Zoo names remain useful
research aliases, but aliases do not create duplicate implementation tasks.

The first implementation is one Mix application. IDs are lowercase,
slash-separated and stable once used by an assembly. A rename requires an
explicit compatibility alias in the catalogue and a migration note.

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
P2 is the first point at which the word durable is earned. P3 chooses a
library through an executable comparison; documentation alone does not move a
candidate to reuse/adapt.

## Stable entries

### Core composition and contracts

| ID | Capability and old Zoo coverage | Disposition | Phase | Initial evidence / delivery note |
| --- | --- | --- | --- | --- |
| `core/operator` | Pure state transition; old operators, Rx transforms, EIP routing pieces | own | P0 | Cure type checks; selected laws may use `P`, behavior uses `X` |
| `core/port` | Named typed input/output face; datatype channels and message endpoints | own | P0→P1 | `T`; bootstrap has function types; ELZ-002/003 add named bindings and minimal graph validation |
| `core/envelope` | Message/command/document/event envelope, correlation, return address, format indicator | own | P0→P1 | `T,X`; bootstrap is minimal, canonical encoding/schema compatibility is `ELZ-003` |
| `core/edge` | Fused versus hop placement and delivery class | own | P0 | `X,A`; no exactly-once promise |
| `core/wiring` | Unit/port/edge declaration, compatibility and required-route checks | own | P0→P1 | `T,X`; ELZ-003 makes minimal graph validation executable; P1 extends it for resilience; no Zoo wiring CLI |
| `core/assembly` | Nested composition behind an outer port contract | own | P0 | `P,T,X`; spike showed nested Cure composition |
| `core/effect` | Data-shaped external request/result boundary | own | P1 | `T,X`; effects cannot be hidden in pure operators |
| `core/grounding` | Claim/evidence record and present-versus-target status | own | P0 | `X` via `mix check`; no whole-repository assurance badge |

### OTP runtime and lifecycle

| ID | Capability and old Zoo coverage | Disposition | Phase | Initial evidence / delivery note |
| --- | --- | --- | --- | --- |
| `runtime/unit` | Unit shell, state ownership and mailbox; old gen_server, singular update queue | adapt | P0 | OTP `GenServer` shell; spike exercised it, volatile state resets on restart |
| `runtime/supervision` | Supervisor/tree, let-it-crash, restart policy | reuse | P0 | OTP `Supervisor`; spike tested restart, Elzoo owns child contract |
| `runtime/host` | Host/application start and effect dispatch; old engine host | adapt | P0 | OTP `Application`/supervision; no custom engine loop initially |
| `runtime/adapter` | Service/channel/process adapter boundary and result translation | own | P0→P1 | `T,X,U`; one adapter per external contract |
| `runtime/faces` | Lean config/control/health/errors/state/manifest conventions | own | P1→P2 | target contract; not seven mandatory APIs in P0 |
| `runtime/telemetry` | Metrics, traces, message history, exception tracking, audit logging | adapt | P3 | `M,U`; candidate `:telemetry`/OpenTelemetry, redaction task first |
| `runtime/registry` | Registered names, local process groups and service discovery | reuse | P2→P4 | OTP `Registry`/`pg` as needed; location is not envelope identity |
| `runtime/os-isolation` | Foreign unit/host/process boundary | adapt | P4 | OTP Port/OS process or service; BEAM process is not security isolation |

### Message delivery and stream behavior

| ID | Capability and old Zoo coverage | Disposition | Phase | Initial evidence / delivery note |
| --- | --- | --- | --- | --- |
| `delivery/idempotency` | Idempotent Receiver/Consumer; duplicate delivery handling | own | P0→P1 | `P,T,X`; bootstrap history is unbounded and not the old bounded-window receiver |
| `delivery/request-reply` | Request-Reply/RPI, correlation identifier and return address | own | P1 | `T,X`; replies are ordinary messages and timeout is explicit |
| `delivery/routing` | Router, content router, filter, recipient list, splitter, expiration | own | P1 | `P,T,X`; fan-out is bounded and declared |
| `delivery/transformation` | Translator, mapper, content filter/enricher merge, anti-corruption | own | P1 | `P,T,X`; effectful lookup is request/reply before merge |
| `delivery/retry-timeout` | Retry/backoff, timeout, catch/fallback, fail-fast | adapt | P1 | Reuse OTP timers/task supervision where sufficient; Elzoo owns attempt/deadline policy and tests it (`P,T,X`) |
| `delivery/circuit-breaker` | Circuit breaker and bulkhead policy | adapt | P1→P3 | Reuse OTP state/supervision and provider pool semantics where sufficient; Elzoo owns the state/permit policy that remains and tests transitions |
| `delivery/backpressure` | Credits, bounded queue, shed-load and handshaking | own | P1 | `T,X,M`; queue limit and rejection are part of port contract |
| `delivery/aggregation` | Aggregator, scatter-gather/API composition, completion/timeout | own | P1→P2 | `T,X`; stateful and needs correlation/retention policy |
| `delivery/resequence` | Resequencer, message sequence, ordered joins | own | P2 | `T,X`; only after ordering assumptions are declared |
| `delivery/dead-letter` | Invalid/dead-letter channel, exception tracking and quarantine | own | P1 | `T,X,M`; never silently drop a rejected message |
| `delivery/pubsub` | Publish-subscribe channel, gen_event, process groups | adapt | P2→P4 | OTP Registry/`pg` or a broker; subscriber loss/replay semantics must be tested |
| `delivery/stream-combinators` | Selected Map/Filter/Scan/Reduce/Window/Combine/Select/Errors | reuse | P1 | Use `Enum`/`Stream` for ordinary transformations; file a focused own piece only for missing stateful/domain policy; Rx subscription/threading is wiring/runtime |
| `delivery/time` | Timer/interval/debounce/delay/timestamp and clock port | adapt | P1 | OTP timer/clock adapter; decisions consume time messages, not wall clock |

### State, durability and workflow

| ID | Capability and old Zoo coverage | Disposition | Phase | Initial evidence / delivery note |
| --- | --- | --- | --- | --- |
| `state/event-log` | Write-ahead log, message store, event sourcing, session log | adapt | P2 | Elzoo owns the append/replay/durability contract; evaluate OTP `disk_log` or a transactional store instead of rebuilding a WAL; recovery/truncation need crash tests |
| `state/outbox` | Transactional client/outbox and guaranteed delivery core | adapt | P2 | Elzoo owns commit/ack semantics; use the selected transactional store/provider, not a second storage engine; `T,X` |
| `state/checkpoint` | Snapshots, low-water mark, retention and steady state | adapt | P2 | Elzoo owns replay equivalence/retention contract; storage implementation is reused/adapted; `P,T,X` |
| `state/schema-evolution` | Upcasters, format/schema indicator and state migration | own | P2 | `T,X`; version compatibility is explicit, not inferred |
| `state/scheduler` | Delayed/recurring jobs and workflow timers | adapt | P2 | Oban candidate; use provider persistence/retry when sufficient, while Elzoo owns job idempotency and adapter contract |
| `workflow/state-machine` | gen_statem, statecharts, process manager, saga | own | P1→P2 | Cure pure state machine plus OTP shell; compensation is a domain contract |
| `state/crdt` | G-/PN-counter, sets, registers, sequences and offline sync | defer | P4 | Only when a product needs replication; laws require merge semantics and clocks |
| `state/replication` | Leader/follower, quorum, replicated log, leases, clocks, partitions | defer | P4 | Do not implement consensus in bootstrap; use an established service/library if needed |
| `workflow/build-graph` | Build-system scheduler/rebuilder, trace store, dry run/checkpoint | defer | P4 | Product-specific; no catalogue build system in the runtime |

### Domain contracts

| ID | Capability and old Zoo coverage | Disposition | Phase | Initial evidence / delivery note |
| --- | --- | --- | --- | --- |
| `domain/value-types` | Decimal/money, date-time/calendar, units of measure, Unicode text | adapt | P3→P4 | Reuse maintained Elixir value libraries where their semantics fit; Elzoo owns currency/rounding/time-zone contracts needed by a product |
| `domain/policy-rules` | Decision tables, business rules and policy templates | defer | P4 | A product must provide a finite rule schema, conflict policy and audit requirement before choosing an evaluator |
| `domain/saas-controls` | Tenant isolation, quota, metering, feature rollout, billing events, SLO/alerts | defer | P4 | Compose from delivery/backpressure and policy pieces; no generic SaaS product layer in the runtime |

### Data and external integrations

| ID | Capability and old Zoo coverage | Disposition | Phase | Candidate / adoption status |
| --- | --- | --- | --- | --- |
| `integration/json` | JSON codec and AI/schema parsing boundary | adapt | P0 | Jason is the only non-OTP library exercised by the spike; adopted for bootstrap |
| `integration/http` | HTTP client/server, URL/cookies, WebSocket/SSE, webhook | adapt | P3 | Req/Finch are candidates; neither is adopted until executable comparison |
| `integration/sql` | Database-per-service, PostgreSQL/SQLite, transactions and CDC | adapt | P2→P3 | Ecto/Postgrex candidates; no database dependency in P0 |
| `integration/jobs` | Durable job queue and scheduled work | adapt | P2 | Oban candidate; not the Elzoo outbox until transaction/retry tests pass |
| `integration/observability` | Telemetry exporter, tracing, logs, SLO/alerts | adapt | P3 | `:telemetry`/OpenTelemetry candidates; redaction and sampling are Elzoo contracts |
| `integration/crypto` | Hash/HMAC/signature/password/TLS/compression | adapt | P3→P4 | Reuse OTP crypto for suitable pure primitives or a maintained adapter for native/TLS work; never hand-write TLS/crypto in Cure |
| `integration/auth-policy` | Cedar/RBAC/ABAC, access token, identity provider, consent | defer | P4 | Candidate only after threat model; policy outputs are untrusted inputs to units |
| `integration/object-store` | Claim check, S3/object storage, large payload/media | adapt | P4 | Provider contract and retention/security review required |
| `integration/message-broker` | Kafka/NATS/RabbitMQ/MQTT/cloud queues and bridge | adapt | P4 | Broker delivery semantics must be translated to Elzoo envelope classes |
| `integration/search-data` | Search, dataframe/columnar/analytics, OCR/media/speech | defer | P4 | Product adapters; no generic data engine in core |
| `integration/identity` | OAuth/OIDC, secrets vault, email/SMS/push/payments | defer | P4 | External provider adapters need threat model and contract tests |
| `integration/ai-model` | LLM function, parser, prompt/schema, agent loop/tools/budgets | defer | P4 | AI output is untrusted input; no agent harness in bootstrap |
| `integration/sdk` | Python/TypeScript/Rust/Go foreign-unit SDKs and MCP | defer | P4 | Build only for an actual cross-process assembly |

### Domain and product assemblies

| ID | Working capability | Disposition | Phase | Made from / reason |
| --- | --- | --- | --- | --- |
| `assembly/ingest-dedup-accumulate` | Bootstrap exemplar | own | P0 | `core/operator` + `delivery/idempotency` + OTP shell; intentionally not bounded/durable |
| `assembly/request-route-retry` | Message resilience | own | P1 | request/reply, routing, timeout/retry, backpressure and dead-letter |
| `assembly/durable-job` | Durable workflow/job | adapt | P2 | event log/outbox/checkpoint plus selected SQL/job adapter |
| `assembly/http-job` | Edge request to durable job | adapt | P3 | selected HTTP adapter + Jason + job/storage + telemetry |
| `assembly/tenant-edge` | Tenant tag/auth/quota/metering/billing | defer | P4 | Old SaaS/request-guard family; needs policy and billing contracts |
| `assembly/ledger-checkout` | Ledger, checkout saga, inventory/payment | defer | P4 | Domain-specific; money and external payment contracts first |
| `assembly/consent-records` | Consent, classified records, FHIR | defer | P4 | Requires policy, redaction, retention and healthcare adapter review |
| `assembly/device-ingest` | IoT dedup/window/alerts/rollout | defer | P4 | Requires device identity, protocol and rollout contracts |
| `assembly/data-pipeline` | Build graph, content cache, dataframe | defer | P4 | Deferred until a real data workload justifies it |
| `assembly/agent-product` | LLM/tool/approval/budgeted loop | defer | P4 | Old AI family is a composition, not a privileged runtime |

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
