# Functional pieces across products

Elzoo groups Pieces by the responsibility and Contract they expose, not by the
screen, company department, framework or model that uses them. The aim is a
small understandable vocabulary that can express many applications. This is a
design discipline, not a claim to have found a universal minimal set of primitives.
See the [coverage cases](capability-coverage.md) and the
[source-backed reference study](research/orchestration-references.md).

## What canonical means here

A canonical capability has one catalogue identity for one coherent public
responsibility. Different implementations can satisfy that Contract. Similar
names do not establish interchangeable behavior: durable and volatile queues,
currency amounts and token counts, or authentication and authorization have
different obligations. A broad family may contain several narrower Pieces.

A Piece need not be a tiny function. Keep behavior together when its invariant
or transaction must be enforced together. Split when callers need independent
policy, lifecycle, effects or evidence. Reuse can happen inside a Piece without
exposing every helper as a catalogue entry.

Four useful scales coexist:

| Scale | Responsibility | Example |
| --- | --- | --- |
| Composition foundation | Express how interfaces, state, effects and delivery connect | Operator, Port, Envelope, Wiring; grounded by core/* |
| Capability Piece | Own one public responsibility and its invariant, or expose a tested upstream recipe | Currency arithmetic, authorization decision, work-item lifecycle, bounded retry |
| Assembly | Coordinate capabilities behind an outer Contract | Invite a member, settle a payment, execute an agent-assisted work item |
| Product | Choose business meaning, policy, UI and deployment | SaaS subscription app, accounting system, task board, agent workstation |

This is not a mandatory four-layer runtime. A product can call a library
Recipe directly or compose pure Operators without a process. An Assembly can
be reused as a Piece. Source dependencies and semantic compatibility are
separate: a successful copy/compile does not prove that two delivery or
transaction contracts match.

## Admission and splitting rules

Before promoting a candidate to an implementation task, write:

1. **Responsibility and caller:** one sentence stating the decision or effect
   it owns, plus a concrete assembly that needs it. Use a second distinct
   use case to challenge generality where available; do not invent callers
   merely to meet a quota. A specialised financial invariant can justify a
   domain Piece even when ordinary SaaS applications never need it.
2. **Interface and invariant:** inputs, outputs, state owner, admissible
   transitions and explicit non-goals. Explain identity scope, units, versioning,
   concurrency, retention and unknown results wherever relevant.
3. **Reuse check:** does an adopted library already satisfy this? If yes, use
   it directly. If translation is necessary, isolate an Adapter. Compare a
   candidate library before authoring a new mechanism. Record why any remaining
   policy belongs to Elzoo; a small wrapper by itself earns no catalogue slot.
4. **Split test:** if callers must coordinate two halves to preserve one atomic
   invariant, keep the invariant behind one interface. If they can independently
   choose policies or providers, separate those choices. A balanced journal post
   is one operation; its debit and credit are not separate callable Pieces.
5. **Failure and evidence:** show at least the dangerous failure path for the
   chosen scenario. Select proofs for pure laws, tests for translation and
   recovery, and named upstream contracts. Do not demand Cure proofs for
   external implementations or label every passing test a proof.
6. **Composition record:** name piece dependencies, provider/version assumptions,
   effects, delivery/ordering guarantees and data classification. Evidence only
   composes when those assumptions are satisfied at the connecting interface.

A planned/deferred inventory entry is a research handle, not a source stub or
an assignment to build it. A library's existence does not make a bundle ready;
its exact usage must be exercised. Keep the current ready subsets unchanged
until their own Contracts and evidence are deliberately extended.

## Distinctions that prevent false reuse

| Keep distinct | Why; possible shared mechanism |
| --- | --- |
| Principal / membership / authorization / approval | Who acts; where they belong; whether an action is permitted; whether a particular proposed action has been consented to. Approval never grants authority the approver does not hold. |
| Work item / run / attempt | Durable intent and acceptance criterion; one execution lifecycle; one try within that run. A failed attempt need not fail the work item, and a process exiting successfully need not satisfy its acceptance criterion. |
| Money / budget / quota / rate limit | Currency arithmetic; bounded spending on a run; an entitlement's allocation; admission over a time interval. Arithmetic may be shared, but units, reset/release rules and consistency differ. |
| Trigger / scheduler / delivery | What creates an event; when it is due; how it reaches a consumer. The same invocation interface does not imply the same loss, replay, ordering or acknowledgement guarantees. |
| State log / audit record / telemetry | Recovery input; attributable security/business history; operational observation. A trace is not a durable audit trail or a financial journal. |
| Message / artifact / data stream | Small structured control; retained content with ownership and integrity; incremental bytes with lifetime/backpressure. A Stream transformation recipe is not a cross-process transport. |
| Cancellation / compensation | Stop or suppress future execution; explicitly counteract an already completed business effect. Neither can erase an external payment or email. |
| Model provider / agent runner / orchestration | Generate output; manage a provider/CLI session and tools; decide work dependencies, approvals, budgets and completion. A model API alone is not a durable job engine. |

Avoid a universal `Account`, `Task`, `Status` or `Event` record that erases these
meanings. Authentication session, conversation history and agent execution
session may share storage but do not share expiration, authority or replay
contracts. The project glossary fixes Elzoo's terms; products retain their
own domain vocabulary behind explicit mappings.

## Engine and Pieces

Keep Zoo's separation: decisions compose, execution supplies the machinery.
Pure transitions remain Cure where it fits. Elixir/OTP supplies process
lifecycle, supervision and ordinary in-process execution. Selected libraries
supply database, job, authentication, model and other implementations. Elzoo
owns the missing policy and the translation between declared Contracts.

The engine role is small and explicit: execute transitions, route messages,
perform declared Effects through Adapters, and enforce the declared lifecycle
and delivery policy. It is not a mandatory global broker, all-purpose task
service or a second implementation of OTP. A library's internal policies remain
upstream-owned; Elzoo's new business decisions should remain inspectable and
separable from the effectful shell.

Dynamic capability discovery, remote workers and sandbox management may be
useful later Assemblies. Do not add them to the composition kernel merely
because a reference product uses them. Developer/agent source discovery uses
the Piece Ledger; runtime discovery is a different capability.

## Agent orchestration is an Assembly

A useful proposed decomposition is:

- work item and acceptance criterion;
- execution lifecycle with attempt identity, parent/child relationships,
  cancellation and restart policy;
- dependency readiness and result correlation;
- bounded resource allocation and concurrency admission;
- authority plus optional approval of an exact action;
- model/runner/tool Adapters with explicit capabilities;
- versioned context selection and artifact references;
- durable state/result delivery and observable execution history.

These responsibilities also appear in invoice approval, asynchronous reports,
onboarding and human task queues. Agent-specific concerns remain explicit:
model output is an untrusted proposal; provider session IDs are not business
identity; generated text is not execution evidence; context/token budgeting is
not money settlement; the product decides what constitutes useful completion.
A tree is one orchestration topology, not the universal model. Support a DAG
only when shared dependencies need it, and specify bounded loops separately
rather than silently calling them acyclic.

For a tool action: validate arguments and current authority, bind any approval
to the actor/resource/action payload and policy version, reserve necessary
resources, then dispatch. If the payload or relevant authority changes before
dispatch, re-evaluate it. Persist the operation identity and observed outcome.
A timeout after dispatch is an **unknown outcome**, not evidence that nothing
happened. Reconcile with the provider or use its idempotency contract before
retrying. Local duplicate suppression alone cannot make an external effect
exactly once.

## How coverage drives work

Use the [coverage cases](capability-coverage.md) as design tests before writing
worker prompts. ELZ-002/003 establish shared contracts; the existing P0–P3 task
DAG remains the executable foundation sequence. The new domain inventory is
demand-led and deferred: those rows are not added to that serial build queue.

Choose one thin working assembly next, identify its missing contracts, adopt
existing implementations through tested recipes, and author only the remainder.
Then exercise a second assembly that reuses the same pieces with different
policy. For example, compare an approval-based refund with approval-based agent
publishing: share the approval mechanism, but preserve different authority,
expiry, settlement and compensation policies. Refine the boundary when that
comparison exposes a false abstraction.

## Relationship to Zoo's book-derived patterns

Keep Enterprise Integration Patterns for routing/correlation/aggregation;
Designing Data-Intensive Applications for storage, replay and consistency;
Release It! for bounded resources, retries and failure containment; and
Domain-Driven Design for context boundaries and language. They provide design
questions and known trade-offs, not a requirement to implement one directory
per named pattern. The [old-family mapping](catalogue.md#mapping-the-old-zoo-families)
remains useful coverage evidence. A named pattern becomes a Piece only when
its caller, invariant and boundary earn that place.
