# ADR-0005: Evaluate Ash as the application foundation; stay upstream by default

Status: proposed adoption direction under ELZ-015; production adoption requires
the boundary checks described below.

## Context

The owner wants reusable Pieces for SaaS, money, users, tasks and agents, with
upstream implementations supplying existing functionality. The owner agrees
to an Ash proof-of-fit and asks us to consider it as the foundation. The owner
also authorizes forks of MIT libraries under balungpisah when modifications
are needed, explicitly retaining upstream when no modification is needed.

## Decision

Make Ash the preferred candidate for the **application action/resource
foundation**. Evaluate its resource actions, authorization, multitenancy and
extensions before authoring corresponding Elzoo mechanisms. This is not a
decision to require Ash in every source bundle or make an Ash Resource the
universal representation of an Operator, Unit or Port.

There are complementary responsibilities:

- Cure supplies selected pure decisions with selected laws when useful.
- Ash supplies declared application actions, resource lifecycle and policies;
  its persistence and job extensions are evaluated at their own boundaries.
- Elixir/OTP supplies execution and supervision. Reactor is a workflow
  execution candidate, not an assumed durable job or universal kernel.
- Elzoo supplies the missing policy, explicit composition Contracts, source
  distribution and evidence ledger. Consumers own their chosen dependencies.

An Ash-based Assembly may directly use public Ash APIs. Do not invent a wrapper
that merely renames them. An actual Cure/Elixir value or Effect translation
earns an Adapter when needed. Do not duplicate a resource's state-transition
policy in Cure merely to attach a proof to a different implementation.

Use upstream releases unless a concrete modification requires a maintained
fork. Follow [the fork policy](../development/08-upstream-and-forks.md); no
Ash fork is needed by this experiment. MIT source and notices stay MIT;
Elzoo-owned source stays Apache-2.0.

## Evidence boundary

`spikes/ash_foundation` is an isolated, locked Mix project. It evaluates
tenant-scoped work intent, sequential state transitions, shared direct/tool
actions, authorization and a volatile supervised-task invocation. The
root `mix setup` fetches its dependencies and `mix check` executes its checks,
while the root dependency graph and ready source bundles remain unchanged.
Its exact observations are in [the spike README](../../spikes/ash_foundation/README.md).

The spike's ETS storage is volatile and non-transactional. It does not establish
safe concurrent transitions, crash recovery or production tenant isolation.
Actor maps are trusted host context, not authenticated credentials. AshAi tool
execution is exercised locally without an LLM or network MCP server. No new
Cure proof or Cure-to-Ash bridge is claimed. Existing Cure checks continue to
ground the existing pure pieces independently.

## Admission before production use

First evaluate AshPostgres and AshOban for a concrete durable Assembly. Require
transactional transition/concurrency checks, actor/tenant propagation from
real authentication, rollback and crash/retry recovery, and safe handling of
unknown external outcomes. Tool exposure must enforce current authority and
any exact-action approval at dispatch. A state machine alone does not supply
durable Work Item/Run/Attempt orchestration.

Copy a selected Ash Recipe into an independent consumer, including its required
configuration/migrations, and run its tests before adding a ready ledger entry.
If a needed pure decision uses Cure, exercise its real call/translation from
an Ash action before claiming that combination. Library DSL validation, tests
and upstream contracts remain distinct from formal proofs.

## Consequences for the task sequence

ELZ-002/003 still define typed pure composition and message contracts, but must
not build a competing resource/action framework. ELZ-009/010 must evaluate
AshPostgres/AshOban and Reactor at the selected durability boundary before
owning equivalent infrastructure. Other extensions remain research candidates,
not installed providers or promises that every catalogue capability is ready.

The independent spike costs dependency download/build time in the development
harness. It deliberately makes that cost measurable without imposing the
same package graph on consumers of unrelated Pieces.
