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
   current approvals. Outputs: decision plus permitted writes, escrowed
   writes and approval requests. State owner: the workflow Run for approvals;
   policies are versioned configuration. Invariants: deny > ask > allow;
   escrowed writes apply only on approval; a changed payload or policy
   version invalidates a prior approval; a child never gains authority its
   parent lacks; approval of an action is not authorization for a different
   action. Non-goals: authentication, identity mapping, UI prompting.
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
   class, not text). Proofs: precedence, escrow-only-on-approval and
   monotonic authority laws over the pure reducer. Tests: payload drift
   invalidation, scope boundaries, replay of approval events rebuilding live
   state. Upstream: Ash policy semantics where used.
6. **Composition record.** Depends on core/envelope schemas, domain/principal
   identity (deferred; stub principals are test inputs only) and
   state/audit-log for retained decisions once that boundary exists.
   Approval decisions are retained records, not telemetry.

## Scope

- define policy, proposal, decision and approval schemas;
- implement the pure reducer and approval binding in Cure;
- select laws for precedence, escrow and non-escalation; test drift and scope;
- compare the Ash policy spike at the boundary and record the division.

## Acceptance

- [ ] DENY precedence, escrow release and non-escalation are selected laws
      passing through mix check.
- [ ] A changed payload or policy version invalidates an earlier approval
      (executable test).
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
