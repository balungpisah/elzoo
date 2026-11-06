# ELZ-024 — Specify authorization decisions and exact-action approval

- Phase: demand-led domain/workflow policy
- Catalogue IDs: domain/authorization, workflow/approval (two Pieces)
- Dependencies: ELZ-003, ELZ-015

## Outcome

Reduce an ordered policy list to one of ALLOW, ASK or DENY for a proposed
action, with DENY taking precedence, ALLOW merging permitted writes, and ASK
holding proposed writes in escrow until an approval bound to the exact action
releases them. Authorization and approval are separate Pieces: approval never
grants authority by itself.

## Admission record

1. **Responsibility and caller.** domain/authorization: decide, from principal,
   tenant, resource, action payload and policy version, whether an action is
   allowed, denied or needs consent. workflow/approval: record a consent
   decision bound to actor + resource + exact payload + policy version, with
   a scope (once, run, root) and expiry/revocation. Callers: C3 refund
   approval, C6 publish approval and child-run authority; C1 invitation
   challenges generality with a human-only flow.
2. **Interface and invariant.** Inputs: ordered policies, action proposal,
   the proposer's bounding authority (the permitted-write set of the actor,
   and for a child run the parent's effective authority) supplied by the
   owning Run from its own state, never carried inside the proposal,
   current approvals, and for an approval event the approver's identity and
   authority. Outputs: decision plus permitted writes, escrowed writes and
   approval requests. State owner: the workflow Run for approvals; policies
   are versioned configuration. Invariants: deny > ask > allow; escrowed
   writes apply only on approval; a changed payload or policy version
   invalidates a prior approval; permitted and escrowed writes are a subset
   of the bounding authority, so a child run's decision never exceeds its
   parent's; an approval is evaluated against the approver's own authority
   and is rejected when the approver could not perform the action or is the
   proposer of the ASK; approval of an action is not authorization for a
   different action. Non-goals: authentication, identity mapping, UI prompting.
3. **Reuse check.** Ash policies (ELZ-015 spike) already answer direct
   allow/deny for resource actions when the consumer chooses Ash; bodyguard
   covers callback authorization. Neither models ASK, escrow, scoped approval
   memory or payload-bound consent; author only that remainder and isolate
   any Ash translation in an Adapter.
4. **Split test.** The reducer's precedence and escrow are one invariant.
   Approval scope, expiry and the prompting channel are separate policies;
   authorization and approval stay distinct Pieces because C3 and C6 need
   different expiry and settlement rules behind the same mechanism.
5. **Failure and evidence.** Dangerous paths: a generated tool argument or
   child run escalating authority; an approval reused after the payload
   changed; a string denylist treated as sufficient (gate on typed effect
   class, not text); an agent approving its own ASK. Proofs: precedence,
   escrow-only-on-approval and bounded-authority (output writes ⊆ bounding
   authority) laws over the pure reducer. Tests: payload drift invalidation,
   self-approval and under-authorized approver rejection, scope boundaries,
   replay of approval events rebuilding live state. Upstream: Ash policy semantics where used.
6. **Composition record.** Depends on core/envelope schemas, domain/principal
   identity (deferred; stub principals are test inputs only) and
   state/audit-log for retained decisions once that boundary exists.
   Approval decisions are retained records, not telemetry.

## Scope

- define policy, proposal, decision and approval schemas;
- implement the pure reducer and approval binding in Cure;
- select laws for precedence, escrow and non-escalation; test drift and scope;
- compare the Ash policy spike at the boundary and record the division.
- re-run the reducer when an approval is applied, with the approver's current
  authority and the current policy version: DENY or a reducer failure at
  release wins over recorded consent; a changed requirement retains the old
  approval as superseded and issues a new request with revision + 1;
- identify an approval request by `(Run, action id, requirement name,
  requirement version, revision)`; a stale revision changes nothing; a
  restored pre-dispatch "approved" action re-enters the reducer, the stored
  approval being an input, never a bypass;
- accept approval evidence only from the configured verifier, for exactly the
  requested requirement, within its declared maximum age, retaining reviewer
  identity and verifier name; whether DENY reasons or ASK prompts are shown
  to the proposer is a declared Assembly setting;
- deny as a proposal any proposal that carries its own policy, bounding
  authority or approval; decide containment on typed rules never model text;
  carry the policy identity (id, version, content hash) on every decision; a
  denial is a result to the proposer and a retained audit record; a static
  tool permission or a schema/route match is an input, never the decision;
  no model turn resolves an ASK (the escrowed write stays escrowed when the
  model replies "approved") (ELZ-025 study).

## Acceptance

- [ ] DENY precedence, escrow release and non-escalation are selected laws
      passing through mix check.
- [ ] A changed payload or policy version invalidates an earlier approval
      (executable test).
- [ ] Release re-evaluation (DENY wins), stale revision, self-approval and
      model-text "approved" leaving escrow intact are executable tests.
- [ ] Authorization and approval are separate IDs with separate Contracts.
- [ ] Ash reuse division is recorded; no duplicate resource policy engine.
- [ ] Contract states no security certification or identity guarantee.

## Evidence and limits

Selected laws ground the reducer; tests ground listed scenarios. Identity,
authentication and durable approval storage remain other Pieces or upstream.

## Out of scope

No identity provider, session system, prompt UI or product permission matrix.

## Reference

Shape observed in Raxol's authorization engine and blast-radius gate; see
docs/research/orchestration-references.md. No code is copied.
