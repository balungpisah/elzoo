# ELZ-006 — Specify backpressure, retry and dead-letter semantics

- Phase: P1 message resilience
- Catalogue IDs: delivery/backpressure, delivery/retry-timeout,
  delivery/dead-letter, delivery/time
- Dependencies: ELZ-004, ELZ-005

## Outcome

Make capacity, overflow, retry, timeout and error classification explicit where
the receiver and Adapter meet. The bounded flow must not silently drop or
acknowledge work outside its Contract.

## Scope

- declare queue/window capacity and admission at saturation;
- distinguish retryable, permanent and unavailable errors;
- specify acknowledgement relative to state/effect completion;
- add tests for overflow, Adapter failure, retry, timeout and recovery;
- use OTP timers/clock messages rather than wall-clock decisions in Cure;
- expose redacted telemetry fields only when runtime needs them.

## Acceptance

- [ ] Saturation returns the documented result and never silently accepts work
      beyond the bound.
- [ ] Error classes, retry limits and timeout behavior are executable.
- [ ] Failed Effect/restart cannot be reported successful without stated
      durability evidence.
- [ ] Selected checks and negative controls run through mix check.
- [ ] Limits distinguish local policy from network-wide delivery guarantees.

## Evidence and limits

Tests ground named capacity/error scenarios; monitoring may ground observed
queue/error counters. Storage and transport remain Adapter/upstream contracts.
No universal exactly-once claim is made.

## Out of scope

No distributed credit protocol, load balancer or chaos platform.
