# ELZ-007 — Reuse ordinary stream pieces and select compatible candidates

- Phase: P1 message resilience
- Catalogue IDs: delivery/request-reply, delivery/routing,
  delivery/transformation, delivery/stream-combinators;
  reuse selection for core/assembly
- Dependencies: ELZ-002, ELZ-003

## Outcome

Build the request/reply, routing and selection Pieces needed by the next
Assembly, selecting compatible Pieces deterministically. Reuse Enum/Stream for
ordinary transformations and maintained OTP facilities before adding new
stream/runtime code.

## Scope

- implement request/reply correlation and return-address use against ELZ-003's
  Envelope and common delivery-result/error/deadline schema; preserve its units
  and unknown-outcome meaning without inventing fields or scheduling timers;
- route/filter/transform only through declared Ports and delivery policies;
- exclusively own candidate identity/ranking/selection metadata, referring to
  ELZ-002 Port descriptors and ELZ-003 delivery policies rather than duplicating
  their fields; define a pure stable selection rule for compatible
  Pieces/Assemblies, with typed rejection for missing/incompatible/ambiguous
  candidates;
- use Enum/Stream for ordinary map/filter/scan behavior and document why any
  owned stateful policy is needed;
- test equivalent candidate/input order, explicit deadline data and route failure cases;
- define these Pieces against the ELZ-002/003 contracts so this task can run
  alongside ELZ-004/005/006; ELZ-008 integrates the actual retry/window policies.

## Acceptance

- [ ] Retain the ELZ-002 positive and negative boundary checks in mix check.

- [ ] Correlation and deadline data use ELZ-003's examples; timeout results use
      that common shape, while timeout execution/classification remains ELZ-006.
- [ ] delivery/time and ELZ-003 shared schemas remain unchanged by this task.
- [ ] Compatible, incompatible, missing and ambiguous candidate cases are
      executable and deterministic.
- [ ] Ordinary stream transformations use Enum/Stream or record a concrete
      reason not to reuse them.
- [ ] Routing and selection do not perform file/network lookup.
- [ ] mix check exercises positive and negative controls without claiming the
      selected candidate is correct beyond its own evidence.

## Evidence and limits

Proof/tests ground determinism, compatibility and named route cases. Candidate
behavior remains each candidate's own grounding; selection does not certify an
implementation. Existing OTP timer behavior is an upstream contract, consumed read-only if needed.

## Out of scope

No retry/window policy implementation (ELZ-005/006), full P1 Assembly
(ELZ-008), package manager, remote registry, AI ranking, custom Rx
implementation or automatic installation.
