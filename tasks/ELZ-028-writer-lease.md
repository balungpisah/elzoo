# ELZ-028 — Specify single-owner leases fenced by record revision

- Phase: demand-led state policy
- Catalogue IDs: state/lease
- Dependencies: ELZ-009, ELZ-010

## Outcome

Decide which single owner may drive a durable Run or job attempt for a
bounded interval and let a replacement take over after expiry, without ever
deciding whether a state write is valid: the record revision fences writes,
the lease only coordinates liveness. Open this task only if the ELZ-010
provider's own ownership contract does not satisfy the invariants below.

## Admission record

1. **Responsibility and caller.** Claim, hold, renew, release and seize a
   lease per key; classify a lease as free, active, stale or ambiguous.
   Callers: assembly/durable-job (ELZ-010) runner ownership; C5 "a worker that
   lost its lease cannot complete the new owner's attempt"; C2 "an expired
   lease cannot overwrite a replacement's artifact" challenges generality with
   a non-agent owner.
2. **Interface and invariant.** Inputs: `claim{key, owner, ttl}`,
   `hold{key, owner}`, `renew{owner, keys, ttl}`, `release{key, owner}`,
   `seize{key, owner, ttl, reason}` (attributable operator takeover),
   `claim_expired{owner, ttl, limit}`, and the store clock. Outputs:
   `held{owner, live}`, `free`, `lease_refused{holder}`, `renewed{keys}`,
   `status ∈ {free, active, stale, ambiguous}`. State owner: the same
   transactional record as the state it guards; expiry is judged by the
   store's clock, never a node clock. Invariants: a lease never authorizes a
   write (the record revision does); lease condition and record change are
   checked in one atomic step; `renew` extends only a live lease, so a renewal
   issued before a handoff and applied after it cannot revive it;
   `claim_expired` results are disjoint across concurrent claimers; stale and
   ambiguous (heartbeat in the future or unreadable) fail closed and their
   release is an explicit, attributable record; a terminal state releases the
   lease atomically; completion from a non-holder is rejected by fencing
   token, never by timestamp comparison. Non-goals: distributed lock service,
   cross-store agreement, authorization.
3. **Reuse check.** Oban/AshOban own locking for their own jobs; Postgres
   advisory locks and `SELECT … FOR UPDATE SKIP LOCKED` are provider
   mechanisms. If the ELZ-010 provider satisfies the invariants, this handle
   stays deferred and the provider contract is named as upstream; only the
   fencing-by-revision and store-clock rules are Elzoo policy where a
   provider lacks them.
4. **Split test.** Lease condition and record CAS share one atomic step and
   stay behind one interface; TTL policy, sweeper cadence and takeover
   authorization are separate Assembly choices.
5. **Failure and evidence.** Dangerous paths: a stale owner whose lease
   expired writes over the replacement's result (must be fenced by revision);
   a late renewal revives an expired lease; two recoverers both take over;
   node-local clock skew judges expiry; claim-next-ready double-claims under
   a lost race. Tests on the double and the selected provider: concurrent
   `claim_expired` disjointness, renewal after handoff, write with expired
   lease refused by revision, claim-next-ready under one transaction. Proofs:
   the status classification over the pure part. Upstream: provider
   transaction and clock semantics are named, not proven.
6. **Composition record.** Depends on ELZ-009 state/checkpoint revision
   semantics and the store clock; used by ELZ-010 and workflow/work-item
   completion; data classification: owner identifiers only.

## Scope

- decide, with ELZ-010's provider evidence, whether this Piece is needed;
- if needed, define the transition, status classification and result schema;
- test the listed dangerous paths on the double and the selected provider.

## Acceptance

- [ ] A write from an expired lease holder is refused by revision (test).
- [ ] Concurrent `claim_expired` never hands one key to two owners (test).
- [ ] Status classification laws run through mix check.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Listed scenarios on two stores; no distributed-lock or cross-store claim.

## Out of scope

Authorization, distributed consensus, job scheduling.

## Reference

Shapes observed in fabric 0.2.0, pixir 0.1.17 and bankai 0.4.0 lease code;
see docs/research/ecosystem-round-2.md. No code is copied.
