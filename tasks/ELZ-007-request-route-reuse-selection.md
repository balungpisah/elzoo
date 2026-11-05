# ELZ-007 — Reuse ordinary stream pieces and select compatible candidates

- Phase: P1 message resilience
- Catalogue IDs: delivery/request-reply, delivery/routing,
  delivery/transformation, delivery/stream-combinators, delivery/time;
  reuse selection for core/assembly
- Dependencies: ELZ-002, ELZ-003

## Outcome

Build the request/reply, routing and selection Pieces needed by the next
Assembly, selecting compatible Pieces deterministically. Reuse Enum/Stream for
ordinary transformations and maintained OTP facilities before adding new
stream/runtime code.

## Scope

- define request/reply correlation, return address and explicit deadline;
- route/filter/transform only through declared Ports and delivery policies;
- define candidate metadata and a pure stable selection rule for compatible
  Pieces/Assemblies, with typed rejection for missing/incompatible/ambiguous
  candidates;
- use Enum/Stream for ordinary map/filter/scan behavior and document why any
  owned stateful policy is needed;
- test equivalent candidate/input order, explicit deadline data and route failure cases;
- define these Pieces against the ELZ-002/003 contracts so this task can run
  alongside ELZ-004/005/006; ELZ-008 integrates the actual retry/window policies.

## Acceptance

- [ ] Request/reply correlation and timeout outcomes are explicit.
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
implementation. OTP timer behavior is an upstream contract.

## Out of scope

No retry/window policy implementation (ELZ-005/006), full P1 Assembly
(ELZ-008), package manager, remote registry, AI ranking, custom Rx
implementation or automatic installation.
